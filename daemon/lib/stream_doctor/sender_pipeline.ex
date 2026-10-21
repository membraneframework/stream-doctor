defmodule StreamDoctor.SenderPipeline do
  @moduledoc """
  Streams an input via RTMP.

  Options: `:input`, `:rtmp_url`, `:on_live` (pid that gets `{:streamer_live, pipeline_pid}` once
  the first video frame reaches the sink).
  """

  use Membrane.Pipeline

  require Membrane.Pad

  alias Membrane.Pad
  alias StreamDoctor.{Encoding, Source}
  alias StreamDoctor.Sink.RTMP

  @spec start_link(StreamDoctor.Input.t(), String.t(), keyword()) :: pid()
  def start_link(input, rtmp_url, opts \\ []) do
    {:ok, _supervisor, pipeline} =
      Membrane.Pipeline.start_link(__MODULE__, [input: input, rtmp_url: rtmp_url] ++ opts)

    pipeline
  end

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      rtmp_url: Keyword.fetch!(opts, :rtmp_url),
      on_live: Keyword.get(opts, :on_live),
      awaiting_tracks: nil
    }

    case Keyword.fetch!(opts, :input) do
      {:synthetic, config} ->
        config |> Source.Synthetic.tracks() |> stream(config, state)

      {:file, path} ->
        {[spec: Source.File.spec(path)], state}
    end
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :demuxer, _ctx, state) do
    tracks |> Source.File.tracks() |> stream(%{}, state)
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_element_start_of_stream(:rtmp_sink, Pad.ref(:video, _id), _ctx, state) do
    if state.on_live, do: send(state.on_live, {:streamer_live, self()})
    {[], state}
  end

  @impl true
  def handle_element_start_of_stream(_child, _pad, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(:rtmp_sink, Pad.ref(kind, _id), _ctx, state) do
    awaiting_tracks = MapSet.delete(state.awaiting_tracks, kind)

    if MapSet.size(awaiting_tracks) == 0 do
      {[terminate: :normal], state}
    else
      {[], %{state | awaiting_tracks: awaiting_tracks}}
    end
  end

  @impl true
  def handle_element_end_of_stream(_child, _pad, _ctx, state) do
    {[], state}
  end

  defp stream(track_builders, config, state) do
    spec = track_builders |> Encoding.tracks(config) |> RTMP.link(state.rtmp_url)

    {[spec: spec], %{state | awaiting_tracks: track_builders |> Map.keys() |> MapSet.new()}}
  end
end
