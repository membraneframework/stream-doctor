defmodule StreamDoctor.MetricTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.Metric

  import Membrane.Time, only: [milliseconds: 1]

  defp run(module, opts, events) do
    Enum.reduce(events, module.init(opts), &module.handle_event/2)
  end

  describe "AvDrift" do
    # Receiver-side events of a stream whose timestamps start at 1400 ms.
    # Frame i has pts 1400 ms + i / fps. Audio symbol m has pts
    # 1400 + m * 30 + shift_ms (the audio content shifted against the
    # video's). Counters are emitted wrapped, as the decoders produce them.
    defp video_recv(range, fps \\ 25) do
      max_frame = StreamDoctor.Probe.Video.MarkerDecoder.max_frame()

      Enum.map(range, fn i ->
        pts = milliseconds(1400) + div(i * Membrane.Time.second(), fps)
        {:video_frame_received, rem(i, max_frame), pts}
      end)
    end

    defp audio_recv(range, shift_ms \\ 0) do
      max_symbol = StreamDoctor.Probe.Audio.MarkerDecoder.max_symbol()

      Enum.map(range, fn m ->
        {:audio_symbol_received, rem(m, max_symbol), milliseconds(1400 + m * 30 + shift_ms)}
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
      assert report.frame_duration_ms == 40
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

    test "reports nil until both tracks are decoded" do
      assert drift(video_recv(0..50)) == nil
      assert drift(audio_recv(0..50)) == nil
      assert drift(audio_recv(0..50) ++ video_recv(0..50)) == nil
    end
  end

  describe "TimeToFirstFrame" do
    defp ttff(events),
      do: Metric.TimeToFirstFrame.report(run(Metric.TimeToFirstFrame, [], events))

    defp watching(at), do: {:streamer_started, {:watching, at}}

    defp missed, do: {:streamer_started, :missed}

    defp seen(at), do: {:first_segment_seen, at}

    test "measures from the streamer starting to the first segment" do
      assert %{status: :measured, ms: 1_900} = ttff([watching(1_500), seen(3_400)])
    end

    test "a viewer that started after the streamer does not measure" do
      assert %{status: :attached_late, ms: nil} = ttff([missed(), seen(3_400)])
    end

    test "a segment older than the streamer is rejected when the start is known first" do
      assert %{status: :attached_late, ms: nil} = ttff([watching(5_000), seen(2_000)])
    end

    test "a segment older than the streamer is rejected when the segment is seen first" do
      assert %{status: :attached_late, ms: nil} = ttff([seen(2_000), watching(5_000)])
    end

    test "a segment seen without a streamer has nothing to measure from" do
      assert %{status: :no_streamer, ms: nil} = ttff([seen(1_200)])
    end

    test "reports waiting until a segment appears" do
      assert %{status: :waiting, ms: nil} = ttff([])
      assert %{status: :waiting, ms: nil} = ttff([watching(1_500)])
    end

    test "a republished streamer is measured from its own start" do
      assert %{status: :measured, ms: 2_000} = ttff([watching(0), watching(30_000), seen(32_000)])
    end

    test "a viewer watching when the second streamer started is not late" do
      assert %{status: :measured, ms: 2_000} = ttff([missed(), watching(30_000), seen(32_000)])
    end

    test "later events do not move the measurement" do
      events = [watching(1_500), seen(3_400), missed(), seen(9_000)]

      assert %{status: :measured, ms: 1_900} = ttff(events)
    end
  end
end
