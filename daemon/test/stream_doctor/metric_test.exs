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

  describe "Frames" do
    defp frames(numbers) do
      max = StreamDoctor.Probe.Video.MarkerDecoder.max_frame()
      Enum.map(numbers, &{:video_frame_received, rem(&1, max), milliseconds(0)})
    end

    defp order(events), do: Metric.Frames.report(run(Metric.Frames, [], events))

    test "frames arriving in order report no fault" do
      assert %{
               reordered: %{count: 0, max_depth: nil, permutations: []},
               missing: %{count: 0, gaps: []},
               duplicated: %{count: 0, repeats: []}
             } = order(frames(0..99))
    end

    test "a swapped pair counts once" do
      assert %{reordered: %{count: 1, max_depth: 1, permutations: [[12, 11, 13]]}} =
               order(frames([10, 12, 11, 13]))
    end

    test "a frame displaced over several others counts once, not once per frame it passed" do
      assert %{reordered: %{count: 1, max_depth: 2, permutations: [[13, 11, 12, 14]]}} =
               order(frames([10, 13, 11, 12, 14]))
    end

    test "a frame displaced over several others is late, not lost" do
      assert %{missing: %{count: 0, gaps: []}, duplicated: %{count: 0}} =
               order(frames([10, 13, 11, 12, 14]))
    end

    test "gaps are not reordering" do
      assert %{reordered: %{count: 0}, missing: %{count: 47, gaps: [[3, 49]]}} =
               order(frames([0, 1, 2, 50, 51]))
    end

    test "repeated numbers are not reordering" do
      assert %{reordered: %{count: 0}, duplicated: %{count: 2, repeats: [[5, 1], [6, 1]]}} =
               order(frames([5, 5, 6, 6, 7]))
    end

    test "a single missing frame is written as one number" do
      assert %{missing: %{count: 1, gaps: [[2]]}} = order(frames([0, 1, 3, 4]))
    end

    test "separate outages are listed separately" do
      assert %{missing: %{count: 15, gaps: [[3, 9], [12, 19]]}} =
               order(frames([0, 1, 2, 10, 11, 20, 21]))
    end

    test "a long outage is one run, not thousands of numbers" do
      assert %{missing: %{count: 4998, gaps: [[2, 4999]]}} = order(frames([0, 1, 5000]))
    end

    test "a hole still open when the stream ends is counted missing" do
      assert %{missing: %{count: 8, gaps: [[12, 19]]}} = order(frames([10, 11, 20]))
    end

    test "nothing below the first frame seen is missing" do
      assert %{missing: %{count: 0, gaps: []}} = order(frames([100, 101, 102]))
    end

    test "a frame below the first one seen is a late join, not a duplicate" do
      assert %{duplicated: %{count: 0}, missing: %{count: 0}} = order(frames([10, 11, 9, 12]))
    end

    test "a number far below the join does not move the join point" do
      assert %{duplicated: %{count: 2, repeats: [[3, 1], [4, 1]]}, missing: %{count: 0}} =
               order(frames([100, 101, 3, 4, 102]))
    end

    test "a frozen frame is one entry with many repeats" do
      assert %{duplicated: %{count: 3, repeats: [[7, 3]]}} = order(frames([7, 7, 7, 7, 8]))
    end

    test "two frames repeating different numbers of times keep their own counts" do
      assert %{duplicated: %{count: 5, repeats: [[5, 2], [6, 3]]}} =
               order(frames([5, 5, 5, 6, 6, 6, 6]))
    end

    test "a replayed run shows up as duplicates and as one deep reordering" do
      assert %{
               reordered: %{count: 1, max_depth: 2},
               duplicated: %{count: 3, repeats: [[1, 1], [2, 1], [3, 1]]}
             } = order(frames([0, 1, 2, 3, 1, 2, 3, 4]))
    end

    test "a frame arriving after its gap settled is counted as a duplicate too" do
      assert %{missing: %{count: 78}, duplicated: %{count: 1, repeats: [[1, 1]]}} =
               order(frames([0, 40, 80, 1]))
    end

    test "a truncated list still totals correctly in count" do
      assert %{missing: %{count: 88, gaps: gaps}} =
               order(frames(Enum.flat_map(0..11, &[&1 * 10, &1 * 10 + 1])))

      assert length(gaps) == 10
      assert Enum.sum(Enum.map(gaps, fn [from, to] -> to - from + 1 end)) < 88
    end

    test "an in-order run across the counter wrap reports nothing" do
      max = StreamDoctor.Probe.Video.MarkerDecoder.max_frame()

      assert %{
               reordered: %{count: 0},
               missing: %{count: 0},
               duplicated: %{count: 0}
             } = order(frames(0..(max + 500)))
    end

    test "reordering across the counter wrap is still detected" do
      max = StreamDoctor.Probe.Video.MarkerDecoder.max_frame()
      unwrapped = [max, max - 1, max + 1]

      assert %{reordered: %{count: 1, max_depth: 1, permutations: [^unwrapped]}} =
               order(frames([max - 2, max, max - 1, max + 1]))
    end

    test "a gap across the counter wrap is one run" do
      max = StreamDoctor.Probe.Video.MarkerDecoder.max_frame()
      run = [max, max + 4]

      assert %{missing: %{count: 5, gaps: [^run]}} = order(frames([max - 2, max - 1, max + 5]))
    end

    test "a repeat across the counter wrap is still a duplicate" do
      max = StreamDoctor.Probe.Video.MarkerDecoder.max_frame()

      assert %{duplicated: %{count: 1, repeats: [[^max, 1]]}} =
               order(frames([max - 1, max, max, max + 1]))
    end

    test "decode order instead of display order shows up as a repeating permutation" do
      assert %{
               reordered: %{
                 count: 3,
                 max_depth: 2,
                 permutations: [[3, 1, 2, 6], [6, 4, 5, 9], [9, 7, 8]]
               }
             } = order(frames([0, 3, 1, 2, 6, 4, 5, 9, 7, 8]))
    end

    test "a reordering still open when the stream ends is still reported" do
      assert %{reordered: %{permutations: [[13, 12]]}} = order(frames([10, 11, 13, 12]))
    end

    test "a frame that jumped far ahead does not drag its distance into the permutation" do
      assert %{reordered: %{max_depth: 99, permutations: [[102, 3, 103]]}} =
               order(frames([100, 101, 102, 3, 103, 104]))
    end

    test "the deepest descent is the one reported" do
      assert %{reordered: %{count: 2, max_depth: 50}, missing: %{count: 107}} =
               order(frames([100, 90, 200, 150, 210]))
    end

    test "a frame without a pts still counts" do
      events = [{:video_frame_received, 7, nil}, {:video_frame_received, 9, nil}]

      assert %{missing: %{count: 1, gaps: [[8]]}} = order(events)
    end

    test "nothing is reported before the first frame" do
      assert %{
               reordered: %{count: nil, max_depth: nil, permutations: []},
               missing: %{count: nil, gaps: []},
               duplicated: %{count: nil, repeats: []}
             } = order([])

      assert %{reordered: %{count: nil}} = order([{:streamer_started, :missed}])
    end

    test "audio and lifecycle events leave the report alone" do
      events = [
        {:video_frame_received, 1, nil},
        {:audio_symbol_received, 9, milliseconds(0)},
        {:streamer_started, :missed},
        {:first_segment_seen, 1},
        {:video_frame_received, 2, nil}
      ]

      assert %{
               reordered: %{count: 0},
               missing: %{count: 0},
               duplicated: %{count: 0}
             } = order(events)
    end
  end
end
