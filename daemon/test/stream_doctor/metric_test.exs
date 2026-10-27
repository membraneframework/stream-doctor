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

  describe "FrameOrder" do
    defp frames(numbers) do
      max = StreamDoctor.Probe.Video.MarkerDecoder.max_frame()
      Enum.map(numbers, &{:video_frame_received, rem(&1, max), milliseconds(0)})
    end

    defp order(events), do: Metric.FrameOrder.report(run(Metric.FrameOrder, [], events))

    test "frames arriving in order report no reordering" do
      assert %{out_of_order: 0, max_depth: nil, permutations: []} = order(frames(0..99))
    end

    test "a swapped pair counts once" do
      assert %{out_of_order: 1, max_depth: 1, permutations: [[12, 11, 13]]} =
               order(frames([10, 12, 11, 13]))
    end

    test "a frame displaced over several others counts once, not once per frame it passed" do
      assert %{out_of_order: 1, max_depth: 2, permutations: [[13, 11, 12, 14]]} =
               order(frames([10, 13, 11, 12, 14]))
    end

    test "gaps are not reordering" do
      assert %{out_of_order: 0, permutations: []} = order(frames([0, 1, 2, 50, 51]))
    end

    test "repeated numbers are not reordering" do
      assert %{out_of_order: 0, permutations: []} = order(frames([5, 5, 6, 6, 7]))
    end

    test "an in-order run across the counter wrap reports nothing" do
      max = StreamDoctor.Probe.Video.MarkerDecoder.max_frame()

      assert %{out_of_order: 0, max_depth: nil, permutations: []} = order(frames(0..(max + 500)))
    end

    test "reordering across the counter wrap is still detected" do
      max = StreamDoctor.Probe.Video.MarkerDecoder.max_frame()

      unwrapped = [max, max - 1, max + 1]

      assert %{out_of_order: 1, max_depth: 1, permutations: [^unwrapped]} =
               order(frames([max - 2, max, max - 1, max + 1]))
    end

    test "decode order instead of display order shows up as a repeating permutation" do
      assert %{
               out_of_order: 3,
               max_depth: 2,
               permutations: [[3, 1, 2, 6], [6, 4, 5, 9], [9, 7, 8]]
             } =
               order(frames([0, 3, 1, 2, 6, 4, 5, 9, 7, 8]))
    end

    test "a reordering still open when the stream ends is still reported" do
      assert %{permutations: [[13, 12]]} = order(frames([10, 11, 13, 12]))
    end

    test "a frame that jumped far ahead does not drag its distance into the permutation" do
      assert %{max_depth: 99, permutations: [[102, 3, 103]]} =
               order(frames([100, 101, 102, 3, 103, 104]))
    end

    test "the deepest descent is the one reported" do
      assert %{out_of_order: 2, max_depth: 50} = order(frames([100, 90, 200, 150, 210]))
    end

    test "a frame without a pts still counts" do
      events = [{:video_frame_received, 7, nil}, {:video_frame_received, 5, nil}]

      assert %{out_of_order: 1, max_depth: 2} = order(events)
    end

    test "nothing is reported before the first frame" do
      assert %{out_of_order: nil, max_depth: nil, permutations: []} = order([])
      assert %{out_of_order: nil} = order([{:streamer_started, :missed}])
    end

    test "audio and lifecycle events leave the report alone" do
      events = [
        {:video_frame_received, 1, nil},
        {:audio_symbol_received, 9, milliseconds(0)},
        {:streamer_started, :missed},
        {:first_segment_seen, 1},
        {:video_frame_received, 2, nil}
      ]

      assert %{out_of_order: 0, permutations: []} = order(events)
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
