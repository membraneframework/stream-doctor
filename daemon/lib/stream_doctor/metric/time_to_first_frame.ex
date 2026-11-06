defmodule StreamDoctor.Metric.TimeToFirstFrame do
  @moduledoc """
  Measures how long the first frame takes to reach the viewer after the streamer starts, the
  connection to the ingest included.

  `ms` is that wait, once both ends have been observed. `status` says why it is `nil` instead:
  the viewer was not watching when the streamer started, or found a frame left over from an
  earlier one (`missed_first_frame`), or there was no streamer at all (`no_streamer`).
  """

  @behaviour StreamDoctor.Metric

  @impl true
  def name do
    :time_to_first_frame
  end

  @impl true
  def new(_opts) do
    %{status: :waiting, first_frame_sent_at: nil, first_frame_arrived_at: nil}
  end

  @impl true
  def record({:streamer_started, {:watching, at}}, %{first_frame_arrived_at: nil} = state) do
    %{state | status: :waiting, first_frame_sent_at: at}
  end

  @impl true
  def record(
        {:streamer_started, :missed},
        %{status: :waiting, first_frame_sent_at: nil, first_frame_arrived_at: nil} = state
      ) do
    %{state | status: :missed_first_frame}
  end

  # A frame already there when the streamer starts came from an earlier run.
  @impl true
  def record({:streamer_started, {:watching, _at}}, %{status: :no_streamer} = state) do
    %{state | status: :missed_first_frame}
  end

  @impl true
  def record({:first_frame_arrived, at}, %{first_frame_arrived_at: nil} = state) do
    %{state | status: status_on_arrival(state, at), first_frame_arrived_at: at}
  end

  @impl true
  def record({:first_frame_arrived, _at}, _state) do
    raise "the first frame cannot arrive twice: a viewer has one watcher"
  end

  @impl true
  def record({:streamer_started, :missed}, _state) do
    raise ":missed cannot follow another event: it is stamped when the viewer is created"
  end

  @impl true
  def record(_event_of_another_metric, state) do
    state
  end

  @impl true
  def report(%{status: :measured} = state) do
    result(:measured, state.first_frame_arrived_at - state.first_frame_sent_at)
  end

  @impl true
  def report(state) do
    result(state.status, nil)
  end

  defp status_on_arrival(%{status: :missed_first_frame}, _at), do: :missed_first_frame
  defp status_on_arrival(%{first_frame_sent_at: nil}, _at), do: :no_streamer
  defp status_on_arrival(%{first_frame_sent_at: sent}, at) when at >= sent, do: :measured
  defp status_on_arrival(_frame_older_than_the_stream, _at), do: :missed_first_frame

  defp result(status, ms) do
    %{status: status, ms: ms}
  end
end
