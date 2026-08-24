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
    # Interleaved decode of a 30 fps stream: frame n covers media up to
    # n * 100/3 ms, and the audio track (delayed by audio_delay_ms in the
    # stream) has decoded up to the matching symbol. Counters are emitted
    # wrapped, as the decoders produce them; audio wraps at 128 within these
    # ranges.
    defp av_events(range, audio_delay_ms \\ 0) do
      max_frame = StreamDoctor.Probe.VideoMarkerDecoder.max_frame()
      max_symbol = StreamDoctor.Probe.AudioMarkerDecoder.max_symbol()

      Enum.flat_map(range, fn i ->
        m = max(div(round(i * 100 / 3) - audio_delay_ms, 30), 0)

        [
          {:video_frame_received, rem(i, max_frame), nil, 0},
          {:audio_symbol_received, rem(m, max_symbol), nil, 0}
        ]
      end)
    end

    test "in-sync tracks report ~0 drift (crossing the audio wrap point)" do
      # 300 frames = 10 s, audio counter wraps at 3.84 s - unwrap exercised
      state = run(Metric.AvDrift, [], av_events(1..300))
      report = Metric.AvDrift.report(state)
      # one symbol (30 ms) of quantization: video position rounds down to the
      # last completed symbol
      assert_in_delta report.drift_ms, 15, 20
      assert_in_delta report.frame_duration_ms, 100 / 3, 0.5
    end

    test "delayed audio track yields positive drift (video leads)" do
      # joins mid-stream, past the point where the audio delay has elapsed
      state = run(Metric.AvDrift, [], av_events(100..400, 120))
      assert_in_delta Metric.AvDrift.report(state).drift_ms, 120, 35
    end

    test "reports nil before enough frames to calibrate the frame duration" do
      state = run(Metric.AvDrift, [], av_events(1..30))
      report = Metric.AvDrift.report(state)
      assert report.drift_ms == nil
      assert report.frame_duration_ms == nil
    end
  end
end
