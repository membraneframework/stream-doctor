defmodule StreamDoctor.Metric.TimeToFirstFrame do
  @moduledoc """
  Time from `:session_started` (the viewer being requested) to the first
  decoded video frame, with the intermediate `:playlist_ready` milestone.
  """

  @behaviour StreamDoctor.Metric

  @impl true
  def name(), do: :ttff

  @impl true
  def init(_opts) do
    %{started_at: nil, playlist_ready_ms: nil, ttff_ms: nil, first_audio_ms: nil}
  end

  @impl true
  def handle_event({:session_started, t}, state), do: %{state | started_at: t}

  def handle_event({:playlist_ready, t}, %{started_at: t0, playlist_ready_ms: nil} = state)
      when t0 != nil,
      do: %{state | playlist_ready_ms: t - t0}

  def handle_event({:video_frame_received, _n, _pts_ms, t}, %{started_at: t0, ttff_ms: nil} = state)
      when t0 != nil,
      do: %{state | ttff_ms: t - t0}

  def handle_event({:audio_symbol_received, _m, _pts_ms, t}, %{started_at: t0, first_audio_ms: nil} = state)
      when t0 != nil,
      do: %{state | first_audio_ms: t - t0}

  def handle_event(_event, state), do: state

  @impl true
  def report(state) do
    %{
      time_to_first_frame_ms: state.ttff_ms,
      time_to_first_audio_ms: state.first_audio_ms,
      playlist_ready_ms: state.playlist_ready_ms
    }
  end
end
