defmodule StreamDoctor.Metric.MinimalLatency do
  @moduledoc """
  Measures how long a frame takes to get from the ingest to being downloadable by the viewer, as the median of up to 50 samples.
  Returns a report with three fields:
    * `ms` - the median of up to 50 samples, one per playlist reload, each taken on the last frame of the newest segment.
    * `latest_samples` - the ten newest samples
    * `status` - the status of the measurement, one of:
      * `:no_streamer` - no streamer has started
      * `:waiting` - the streamer has started, but the ingest has not yet started
      * `:measured` - the ingest has started and at least one sample has been taken
      * `:missed_the_stream` - the ingest started before the streamer, so no sample could be taken
      * `:timeline_broken` - the timeline broke before a sample could be taken
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
