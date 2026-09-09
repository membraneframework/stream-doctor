defmodule StreamDoctor.SenderPipeline.Rebase do
  @moduledoc false

  # Shifts both tracks so the video starts at pts 0. Membrane.RTMP.Sink does
  # that to the video alone (its `reset_timestamps: false` has no effect, the
  # state key is misspelt), which skews the sync by the video's first pts.
  # Audio that starts before the video ends up with negative pts.

  use Membrane.Filter, flow_control_hints?: false

  require Membrane.Pad

  alias Membrane.Pad

  def_input_pad(:input, accepted_format: _any, availability: :on_request)
  def_output_pad(:output, accepted_format: _any, availability: :on_request)

  @impl true
  def handle_init(_ctx, _opts), do: {[], %{base: nil, held_audio: []}}

  @impl true
  def handle_stream_format(Pad.ref(:input, kind), format, _ctx, state) do
    {[stream_format: {Pad.ref(:output, kind), format}], state}
  end

  @impl true
  def handle_buffer(Pad.ref(:input, :video), buffer, _ctx, %{base: nil} = state) do
    state = %{state | base: buffer.pts}
    actions = release_audio(state) ++ [buffer: {Pad.ref(:output, :video), shift(buffer, state)}]
    {actions, %{state | held_audio: []}}
  end

  def handle_buffer(Pad.ref(:input, :audio), buffer, ctx, %{base: nil} = state) do
    if Map.has_key?(ctx.pads, Pad.ref(:input, :video)) do
      {[], %{state | held_audio: [buffer | state.held_audio]}}
    else
      state = %{state | base: 0}
      {[buffer: {Pad.ref(:output, :audio), shift(buffer, state)}], state}
    end
  end

  def handle_buffer(Pad.ref(:input, kind), buffer, _ctx, state) do
    {[buffer: {Pad.ref(:output, kind), shift(buffer, state)}], state}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, :audio), _ctx, %{base: nil} = state) do
    state = %{state | base: 0}
    actions = release_audio(state) ++ [end_of_stream: Pad.ref(:output, :audio)]
    {actions, %{state | held_audio: []}}
  end

  def handle_end_of_stream(Pad.ref(:input, kind), _ctx, state) do
    {[end_of_stream: Pad.ref(:output, kind)], state}
  end

  defp release_audio(%{held_audio: []}), do: []

  defp release_audio(state) do
    buffers = state.held_audio |> Enum.reverse() |> Enum.map(&shift(&1, state))
    [buffer: {Pad.ref(:output, :audio), buffers}]
  end

  defp shift(buffer, %{base: base}) do
    %{buffer | pts: buffer.pts - base, dts: buffer.dts && buffer.dts - base}
  end
end
