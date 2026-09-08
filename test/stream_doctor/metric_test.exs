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

      assert [%{frame: 2, latency_ms: 2977}, %{frame: 1, latency_ms: 3000}] =
               report.latest_samples
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
    # Receiver-side events of a 25 fps stream whose timestamps start at
    # 1400 ms: frame i has pts 1400 + i * 40; audio symbol m has pts
    # 1400 + m * 30 + shift_ms (the audio content shifted against the
    # video's). Counters are emitted wrapped, as the decoders produce them.
    # Arrival times are irrelevant to the metric and set to 0.
    defp video_recv(range) do
      max_frame = StreamDoctor.Probe.VideoMarkerDecoder.max_frame()
      Enum.map(range, fn i -> {:video_frame_received, rem(i, max_frame), 1400 + i * 40, 0} end)
    end

    defp audio_recv(range, shift_ms \\ 0) do
      max_symbol = StreamDoctor.Probe.AudioMarkerDecoder.max_symbol()

      Enum.map(range, fn m ->
        {:audio_symbol_received, rem(m, max_symbol), 1400 + m * 30 + shift_ms, 0}
      end)
    end

    # segment-like interleaving: a burst of video, then the matching audio
    defp av_events(seconds, shift_ms \\ 0, first_second \\ 0) do
      Enum.flat_map(first_second..(first_second + seconds - 1)//1, fn s ->
        video_recv((s * 25)..(s * 25 + 24)) ++
          audio_recv(div(s * 1000, 30)..div((s + 1) * 1000 - 1, 30), shift_ms)
      end)
    end

    defp drift(events), do: Metric.AvDrift.report(run(Metric.AvDrift, [], events)).drift_ms

    test "in-sync tracks report 0 drift (crossing the audio wrap point)" do
      # 10 s of stream; the audio counter wraps at 3.84 s
      assert drift(av_events(10)) == 0
      report = Metric.AvDrift.report(run(Metric.AvDrift, [], av_events(10)))
      assert report.frame_duration_ms == 40.0
    end

    test "audio content later than the video's yields positive drift" do
      assert_in_delta drift(av_events(10, 200)), 200, 1
      assert_in_delta drift(av_events(10, -120)), -120, 1
    end

    test "joining mid-stream resolves the wrapped symbol against the video" do
      # first symbol seen is deep into the counter's cycles
      assert_in_delta drift(av_events(6, 150, 30)), 150, 1
      # ...even at the largest resolvable drift
      assert_in_delta drift(av_events(6, 1800, 30)), 1800, 1
      assert_in_delta drift(av_events(6, -1800, 30)), -1800, 1
    end

    test "is independent of arrival times" do
      bursty =
        av_events(10)
        |> Enum.with_index()
        |> Enum.map(fn {event, i} -> put_elem(event, 3, 1000 + rem(i * 7919, 3000)) end)

      assert drift(bursty) == 0
    end

    test "reports nil until both tracks are decoded" do
      assert drift(video_recv(0..50)) == nil
      assert drift(audio_recv(0..50)) == nil
      assert drift(audio_recv(0..50) ++ video_recv(0..50)) == nil
    end
  end
end
