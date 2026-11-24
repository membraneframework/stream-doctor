defmodule StreamDoctor.Metric.PlaylistRequests do
  @max_samples 50
  @evidence 10

  @moduledoc """
  Counts how the media playlist reloads were answered and how long the answers took. The requests
  made before the playlist first listed a segment are not counted.

  Returns a report with six fields:
    * `requests` - the number of reloads
    * `failed` - the reloads answered with anything but a 200, timeouts and connection errors included
    * `timeouts` - the reloads that got no answer in time
    * `statuses` - the number of answers per HTTP status
    * `ms` - the median time of up to #{@max_samples} newest answers, whatever their status
    * `latest_samples` - the times of the #{@evidence} newest answers
  """

  @behaviour StreamDoctor.Metric

  alias StreamDoctor.Metric

  @impl true
  def name do
    :playlist_requests
  end

  @impl true
  def new(_opts) do
    %{requests: 0, failed: 0, timeouts: 0, statuses: %{}, samples: []}
  end

  @impl true
  def record({:playlist_requested, :timeout, _took_ms}, state) do
    %{
      state
      | requests: state.requests + 1,
        failed: state.failed + 1,
        timeouts: state.timeouts + 1
    }
  end

  @impl true
  def record({:playlist_requested, :error, _took_ms}, state) do
    %{state | requests: state.requests + 1, failed: state.failed + 1}
  end

  @impl true
  def record({:playlist_requested, status, took_ms}, state) do
    failed = if status == 200, do: state.failed, else: state.failed + 1

    %{
      state
      | requests: state.requests + 1,
        failed: failed,
        statuses: Map.update(state.statuses, status, 1, &(&1 + 1)),
        samples: Enum.take([took_ms | state.samples], @max_samples)
    }
  end

  @impl true
  def record(_event_of_another_metric, state) do
    state
  end

  @impl true
  def report(state) do
    state
    |> Map.take([:requests, :failed, :timeouts, :statuses])
    |> Map.merge(%{
      ms: Metric.median(state.samples),
      latest_samples: Enum.take(state.samples, @evidence)
    })
  end
end
