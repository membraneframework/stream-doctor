defmodule StreamDoctor.Metric.AvailabilityLatency do
  @max_samples 50
  @evidence 10

  @moduledoc """
  Measures how long a frame takes to get from the streamer to being downloadable by the viewer, as the median of up to #{@max_samples} samples.
  Returns a report with three fields:
    * `ms` - the median of up to #{@max_samples} samples, one per segment the playlist was seen to add, each taken on the segment's last decoded frame: from when the streamer sent it to when the playlist listed the segment.
    * `latest_samples` - the #{@evidence} newest samples
    * `status` - `:waiting` until the first sample is taken, `:measured` from then on
  """

  @behaviour StreamDoctor.Metric

  alias StreamDoctor.Probe.Video.Bar

  @sent_window 10_000
  @segment_window 5

  @impl true
  def name do
    :availability_latency
  end

  @impl true
  def new(_opts) do
    %{samples: [], sent: %{}, chunks: %{}, listed: %{}, last_sent: %{}}
  end

  @impl true
  def record({:video_frame_sent, number, at}, state) do
    forgotten = Integer.mod(number - @sent_window, Bar.max_frame())
    %{state | sent: state.sent |> Map.put(number, at) |> Map.delete(forgotten)}
  end

  @impl true
  def record({:video_chunk_received, segment, pts}, state) do
    put_in(state.chunks[pts], segment)
  end

  @impl true
  def record({:video_frame_received, number, pts}, state) do
    with {segment, chunks} when segment != nil <- Map.pop(state.chunks, pts),
         {:ok, sent_at} <- Map.fetch(state.sent, number) do
      last_sent = Map.update(state.last_sent, segment, sent_at, &max(&1, sent_at))
      sample(%{state | chunks: chunks, last_sent: last_sent}, segment)
    else
      _frame_of_no_known_segment_or_streamer -> state
    end
  end

  @impl true
  def record({:segment_available, segment, at}, state) do
    oldest = segment - @segment_window

    %{
      state
      | listed: state.listed |> Map.put(segment, at) |> Map.filter(&(elem(&1, 0) >= oldest)),
        last_sent: Map.filter(state.last_sent, &(elem(&1, 0) >= oldest)),
        chunks: Map.filter(state.chunks, &(elem(&1, 1) >= oldest))
    }
    |> sample(segment)
  end

  @impl true
  def record(_event_of_another_metric, state) do
    state
  end

  @impl true
  def report(state) do
    samples = Enum.map(state.samples, fn {_segment, ms} -> ms end)
    status = if samples == [], do: :waiting, else: :measured
    %{status: status, ms: median(samples), latest_samples: Enum.take(samples, @evidence)}
  end

  defp sample(state, segment) do
    with {:ok, listed_at} <- Map.fetch(state.listed, segment),
         {:ok, sent_at} <- Map.fetch(state.last_sent, segment) do
      samples = [{segment, listed_at - sent_at} | List.keydelete(state.samples, segment, 0)]
      %{state | samples: Enum.take(samples, @max_samples)}
    else
      :error -> state
    end
  end

  defp median([]) do
    nil
  end

  defp median(samples) do
    sorted = Enum.sort(samples)
    Enum.at(sorted, div(length(sorted), 2))
  end
end
