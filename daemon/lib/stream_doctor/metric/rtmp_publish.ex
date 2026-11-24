defmodule StreamDoctor.Metric.RtmpPublish do
  @moduledoc """
  Reports whether the ingest accepted the RTMP publish and how long that took.

  Returns a map with `status` and `connect_ms`. `connect_ms` is the time from the streamer
  starting to the ingest accepting the publish, in milliseconds.
  The `status` can be one of:
  * `:connecting` - the ingest has not accepted the publish yet
  * `:connected` - the ingest accepted the publish
  * `:failed` - the streamer ended with an error before the ingest accepted the publish
  * `:dropped` - the streamer ended with an error after the ingest accepted the publish
  """

  @behaviour StreamDoctor.Metric

  @impl true
  def name do
    :rtmp_publish
  end

  @impl true
  def new(_opts) do
    %{status: :connecting, started_at: nil, connected_at: nil}
  end

  @impl true
  def record({:streamer_started, {:watching, at}}, state) do
    %{state | started_at: at}
  end

  @impl true
  def record({:streamer_connected, at}, state) do
    %{state | status: :connected, connected_at: at}
  end

  @impl true
  def record(:streamer_failed, %{status: :connecting} = state) do
    %{state | status: :failed}
  end

  @impl true
  def record(:streamer_failed, %{status: :connected} = state) do
    %{state | status: :dropped}
  end

  @impl true
  def record(_event_of_another_metric, state) do
    state
  end

  @impl true
  def report(state) do
    %{
      status: state.status,
      connect_ms: state.connected_at && state.connected_at - state.started_at
    }
  end
end
