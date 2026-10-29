defmodule StreamDoctor.CollectorTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.Collector
  alias StreamDoctor.Metric

  test "folds reported events and serves reports" do
    {:ok, collector} =
      Collector.start_link([
        {Metric.AvDrift, []},
        {Metric.TimeToFirstFrame, []},
        {Metric.Frames, []}
      ])

    for i <- 0..2 do
      Collector.event(
        collector,
        {:video_frame_received, i, Membrane.Time.milliseconds(i * 40)}
      )
    end

    Collector.event(collector, {:audio_symbol_received, 1, Membrane.Time.milliseconds(30)})

    Collector.event(collector, {:streamer_started, {:watching, 500}})
    Collector.event(collector, {:first_segment_seen, 1_700})

    assert %{
             av_drift: %{drift_ms: 0},
             time_to_first_frame: %{status: :measured, ms: 1_200},
             frames: %{reordered: %{count: 0}, missing: %{count: 0}, duplicated: %{count: 0}}
           } = Collector.report(collector)
  end
end
