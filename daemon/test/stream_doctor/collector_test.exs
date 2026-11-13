defmodule StreamDoctor.CollectorTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.Collector
  alias StreamDoctor.Metric

  test "folds reported events and serves reports" do
    {:ok, collector} =
      Collector.start_link([
        {Metric.AvDrift, []},
        {Metric.TimeToFirstFrame, []},
        {Metric.Frames, []},
        {Metric.AvailabilityLatency, []}
      ])

    Collector.record(collector, {:streamer_started, {:watching, 500}})
    Collector.record(collector, {:ingest_started, 580})

    for i <- 0..2 do
      Collector.record(
        collector,
        {:video_frame_received, i, Membrane.Time.milliseconds(i * 40)}
      )
    end

    Collector.record(collector, {:audio_symbol_received, 1, Membrane.Time.milliseconds(30)})
    Collector.record(collector, {:first_frame_arrived, 1_700})
    Collector.record(collector, {:media_available, Membrane.Time.seconds(2), 3_000})

    assert %{
             av_drift: %{drift_ms: 0},
             time_to_first_frame: %{status: :measured, ms: 1_200},
             frames: %{reordered: %{count: 0}, missing: %{count: 0}, duplicated: %{count: 0}},
             availability_latency: %{status: :measured, ms: 420}
           } = Collector.report(collector)
  end
end
