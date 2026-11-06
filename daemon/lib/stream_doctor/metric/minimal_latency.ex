defmodule StreamDoctor.Metric.MinimalLatency do
  @moduledoc """
  Measures the floor of the output latency: the time from a frame reaching the sender's sink
  to the media holding it being listed for download.

    * `status` - `measured` once there is a number, `waiting` before that, or why there will
      not be one: the viewer did not watch one stream from its ingest (`missed_the_stream`),
      the stream broke its own published timeline (`timeline_broken`), or nobody was
      streaming (`no_streamer`)
    * `ms` - the median of up to 50 samples, one per playlist reload, each taken on the last
      frame of the newest segment that reload brought, the frame that waited least
    * `latest_samples` - the ten newest samples
  """

  @behaviour StreamDoctor.Metric

  @max_samples 50
  @evidence 10

  @impl true
  def name do
    :minimal_latency
  end

  @impl true
  def new(_opts) do
    %{status: :no_streamer, ingest_started_at: nil, samples: []}
  end

  @impl true
  def record({:streamer_started, _basis}, %{status: :no_streamer} = state) do
    %{state | status: :waiting}
  end

  @impl true
  def record({:streamer_started, _later_streamer}, state) do
    state
  end

  @impl true
  def record({:ingest_started, at}, %{ingest_started_at: nil} = state) do
    %{state | ingest_started_at: at}
  end

  # A second ingest restarts the clock the samples are anchored on.
  @impl true
  def record({:ingest_started, _at}, state) do
    %{state | status: :missed_the_stream}
  end

  @impl true
  def record({:media_available, _media_end, _at}, %{status: :timeline_broken}) do
    raise "media cannot be published after the timeline broke: the watch ended with it"
  end

  @impl true
  def record({:media_available, media_end, at}, %{ingest_started_at: anchor} = state)
      when anchor != nil and state.status in [:waiting, :measured] do
    sample = at - anchor - Membrane.Time.as_milliseconds(media_end, :round)
    %{state | status: :measured, samples: Enum.take([sample | state.samples], @max_samples)}
  end

  @impl true
  def record({:media_available, _media_end, _at}, state) do
    state
  end

  @impl true
  def record({:timeline_broken, _reason}, %{status: :timeline_broken}) do
    raise "the timeline cannot break twice: the watch ends with it"
  end

  @impl true
  def record({:timeline_broken, :missed_start}, state) do
    %{state | status: :missed_the_stream}
  end

  @impl true
  def record({:timeline_broken, _the_stream_broke_it}, state) do
    %{state | status: :timeline_broken}
  end

  @impl true
  def record(_event_of_another_metric, state) do
    state
  end

  @impl true
  def report(state) do
    %{
      status: state.status,
      ms: median(state.samples),
      latest_samples: Enum.take(state.samples, @evidence)
    }
  end

  defp median([]) do
    nil
  end

  defp median(samples) do
    sorted = Enum.sort(samples)
    Enum.at(sorted, div(length(sorted), 2))
  end
end
