defmodule StreamDoctor.MetricTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.Metric

  import Membrane.Time, only: [milliseconds: 1]

  defp run(module, opts, events) do
    Enum.reduce(events, module.init(opts), &module.handle_event/2)
  end

  describe "AvDrift" do
    # Receiver-side events of a stream whose timestamps start at 1400 ms:
    # frame i has pts 1400 ms + i / fps; audio symbol m has pts
    # 1400 + m * 30 + shift_ms (the audio content shifted against the
    # video's). Counters are emitted wrapped, as the decoders produce them.
    # Arrival times are irrelevant to the metric and set to 0.
    defp video_recv(range, fps \\ 25) do
      max_frame = StreamDoctor.Probe.Video.MarkerDecoder.max_frame()

      Enum.map(range, fn i ->
        pts = milliseconds(1400) + div(i * Membrane.Time.second(), fps)
        {:video_frame_received, rem(i, max_frame), pts, 0}
      end)
    end

    defp audio_recv(range, shift_ms \\ 0) do
      max_symbol = StreamDoctor.Probe.Audio.MarkerDecoder.max_symbol()

      Enum.map(range, fn m ->
        {:audio_symbol_received, rem(m, max_symbol), milliseconds(1400 + m * 30 + shift_ms), 0}
      end)
    end

    # segment-like interleaving: a burst of video, then the matching audio
    defp av_events(seconds, shift_ms \\ 0, first_second \\ 0, fps \\ 25) do
      Enum.flat_map(first_second..(first_second + seconds - 1)//1, fn s ->
        video_recv((s * fps)..(s * fps + fps - 1), fps) ++
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

    test "a frame duration that isn't whole milliseconds doesn't ramp" do
      # 30 fps for 10 minutes, across the video counter's wrap at 16384
      assert drift(av_events(600, 0, 0, 30)) == 0
      assert_in_delta drift(av_events(600, 200, 0, 30)), 200, 1
      assert_in_delta drift(av_events(60, 200, 300, 30)), 200, 1
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
