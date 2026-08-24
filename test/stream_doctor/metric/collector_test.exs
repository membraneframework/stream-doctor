defmodule StreamDoctor.Metric.CollectorTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.Metric
  alias StreamDoctor.Metric.Collector

  test "folds reported events and serves reports" do
    {:ok, collector} = Collector.start_link([{Metric.Latency, [mode: :latest]}])

    Collector.event(collector, {:video_frame_sent, 1, 100})
    Collector.event(collector, {:video_frame_received, 1, nil, 500})

    assert %{latency: %{latency_ms: 400, frames_matched: 1}} = Collector.report(collector)
  end

  test "event_and_report returns the updated report in one step" do
    {:ok, collector} = Collector.start_link([{Metric.Latency, [mode: :latest]}])

    Collector.event(collector, {:video_frame_sent, 7, 1000})

    assert %{latency: %{latency_ms: 250}} =
             Collector.event_and_report(collector, {:video_frame_received, 7, nil, 1250})
  end

  test "receives broadcast send events" do
    {:ok, collector} = Collector.start_link([{Metric.Latency, [mode: :latest]}])

    Collector.broadcast_send_event({:video_frame_sent, 3, 2000})

    assert %{latency: %{latency_ms: 500}} =
             Collector.event_and_report(collector, {:video_frame_received, 3, nil, 2500})
  end
end
