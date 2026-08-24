defmodule StreamDoctor.MetricTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.Metric

  defp run(module, opts, events) do
    Enum.reduce(events, module.init(opts), &module.handle_event/2)
  end

  describe "resolve/1" do
    test "nil selects all metrics" do
      assert {:ok, specs} = Metric.resolve(nil)
      assert length(specs) == length(Metric.names())
    end

    test "resolves known names and rejects unknown ones" do
      assert {:ok, [{Metric.Latency, []}, {Metric.AvDrift, []}]} =
               Metric.resolve(["latency", "av_drift"])

      assert {:error, {:unknown_metric, "nope"}} = Metric.resolve(["latency", "nope"])
    end
  end

  describe "Latency" do
    test "matches received frames against sent ones" do
      state =
        run(Metric.Latency, [], [
          {:video_frame_sent, 1, 1000},
          {:video_frame_sent, 2, 1033},
          {:video_frame_received, 1, 40.0, 4000},
          {:video_frame_received, 2, 73.0, 4010},
          {:video_frame_received, 99, 106.0, 4020},
          {:undecoded, :video, :parity_mismatch, 4030}
        ])

      report = Metric.Latency.report(state)
      assert report.frames_matched == 2
      assert report.frames_unmatched == 1
      assert report.frames_undecoded == 1
      assert [%{frame: 2, latency_ms: 2977}, %{frame: 1, latency_ms: 3000}] = report.latest_samples
    end

    test ":segment mode reports the first frame of the latest segment" do
      state =
        run(Metric.Latency, [mode: :segment], [
          {:video_frame_sent, 1, 1000},
          {:video_frame_sent, 2, 1033},
          {:video_frame_sent, 3, 1066},
          # first segment batch
          {:video_frame_received, 1, nil, 4000},
          {:video_frame_received, 2, nil, 4010},
          # >500 ms gap = new segment
          {:video_frame_received, 3, nil, 6000}
        ])

      report = Metric.Latency.report(state)
      assert report.segments_seen == 2
      assert report.latency_ms == 6000 - 1066
      assert report.segment_latencies == [4934, 3000]
    end

    test ":latest mode reports the latest matched frame" do
      state =
        run(Metric.Latency, [mode: :latest], [
          {:video_frame_sent, 1, 1000},
          {:video_frame_sent, 2, 2000},
          {:video_frame_received, 1, nil, 1500},
          {:video_frame_received, 2, nil, 2700}
        ])

      report = Metric.Latency.report(state)
      assert report.latency_ms == 700
      refute Map.has_key?(report, :segments_seen)
    end
  end

  describe "TimeToFirstFrame" do
    test "measures milestones relative to session start" do
      state =
        run(Metric.TimeToFirstFrame, [], [
          {:session_started, 1000},
          {:playlist_ready, 3000},
          {:video_frame_received, 7, nil, 4500},
          {:audio_symbol_received, 3, nil, 4600},
          # later frames don't move the result
          {:video_frame_received, 8, nil, 9999}
        ])

      assert Metric.TimeToFirstFrame.report(state) == %{
               time_to_first_frame_ms: 3500,
               time_to_first_audio_ms: 3600,
               playlist_ready_ms: 2000
             }
    end

    test "reports nils before the milestones happen" do
      state = run(Metric.TimeToFirstFrame, [], [{:session_started, 1000}])

      assert Metric.TimeToFirstFrame.report(state) == %{
               time_to_first_frame_ms: nil,
               time_to_first_audio_ms: nil,
               playlist_ready_ms: nil
             }
    end
  end

  describe "AvDrift" do
    # 30 fps video (frame n at pts n * 100/3 ms), audio symbol m at m * 30 ms
    defp video_event(n, offset_ms), do: {:video_frame_received, n, n * 100 / 3 + offset_ms, 0}
    defp audio_event(m, offset_ms), do: {:audio_symbol_received, m, m * 30 + offset_ms, 0}

    test "in-sync tracks report ~0 drift" do
      events =
        Enum.flat_map(1..30, fn i -> [video_event(i, 0), audio_event(i, 0)] end)

      state = run(Metric.AvDrift, [], events)
      report = Metric.AvDrift.report(state)
      assert_in_delta report.drift_ms, 0, 1
      assert_in_delta report.frame_duration_ms, 100 / 3, 0.1
    end

    test "audio shifted later on the timeline yields negative drift" do
      events =
        Enum.flat_map(1..30, fn i -> [video_event(i, 0), audio_event(i, 120)] end)

      state = run(Metric.AvDrift, [], events)
      assert_in_delta Metric.AvDrift.report(state).drift_ms, -120, 1
    end

    test "unwraps counters across the wrap point" do
      max_symbol = StreamDoctor.Probe.AudioMarkerDecoder.max_symbol()

      # the marker counter wraps but the stream pts keeps growing
      events =
        Enum.flat_map((max_symbol - 5)..(max_symbol + 5), fn i ->
          [video_event(i, 0), {:audio_symbol_received, rem(i, max_symbol), i * 30, 0}]
        end)

      state = run(Metric.AvDrift, [], events)
      assert_in_delta Metric.AvDrift.report(state).drift_ms, 0, 1
    end

    test "ignores events without pts" do
      state =
        run(Metric.AvDrift, [], [
          {:video_frame_received, 1, nil, 0},
          {:audio_symbol_received, 1, nil, 0}
        ])

      assert Metric.AvDrift.report(state).drift_ms == nil
    end
  end
end
