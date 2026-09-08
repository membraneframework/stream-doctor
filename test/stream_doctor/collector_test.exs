defmodule StreamDoctor.CollectorTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.Metric
  alias StreamDoctor.Collector

  test "folds reported events and serves reports" do
    {:ok, collector} = Collector.start_link([{Metric.AvDrift, []}])

    for i <- 0..2, do: Collector.event(collector, {:video_frame_received, i, i * 40, 0})
    Collector.event(collector, {:audio_symbol_received, 1, 30, 0})

    assert %{av_drift: %{drift_ms: 0}} = Collector.report(collector)
  end
end
