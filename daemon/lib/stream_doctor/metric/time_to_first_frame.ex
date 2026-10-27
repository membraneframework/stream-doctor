defmodule StreamDoctor.Metric.TimeToFirstFrame do
  @moduledoc """
  Measures how long the first HLS segment takes to appear after the streamer starts, which
  includes establishing the connection to the ingest.

  Reported only when the viewer was already watching when the streamer started, since the moment
  a segment becomes available leaves no trace to read afterwards. With a master playlist the
  measurement follows its first video variant.
  """

  @behaviour StreamDoctor.Metric

  @impl true
  def name do
    :time_to_first_frame
  end

  @impl true
  def init(_opts) do
    %{streamer: nil, first_segment_at: nil}
  end

  @impl true
  def handle_event({:streamer_started, basis}, %{first_segment_at: nil} = state) do
    %{state | streamer: basis}
  end

  @impl true
  def handle_event({:streamer_started, basis}, %{streamer: nil} = state) do
    %{state | streamer: basis}
  end

  @impl true
  def handle_event({:first_segment_seen, at}, %{first_segment_at: nil} = state) do
    %{state | first_segment_at: at}
  end

  @impl true
  def handle_event(_event, state) do
    state
  end

  @impl true
  def report(%{first_segment_at: nil}) do
    result(:waiting, nil)
  end

  def report(%{streamer: nil}) do
    result(:no_streamer, nil)
  end

  def report(%{streamer: {:watching, at}, first_segment_at: seen}) when seen >= at do
    result(:measured, seen - at)
  end

  def report(_unmeasurable) do
    result(:attached_late, nil)
  end

  defp result(status, ms) do
    %{status: status, ms: ms}
  end
end
