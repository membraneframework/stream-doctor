defmodule StreamDoctor.MetricTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.Metric

  import Membrane.Time, only: [milliseconds: 1]

  defp run(module, opts, events) do
    Enum.reduce(events, module.new(opts), &module.record/2)
  end

  describe "AvDrift" do
    # Receiver-side events of a stream whose timestamps start at 1400 ms.
    # Frame i has pts 1400 ms + i / fps. Audio symbol m has pts
    # 1400 + m * 30 + shift_ms (the audio content shifted against the
    # video's). Counters are emitted wrapped, as the decoders produce them.
    defp video_recv(range, fps \\ 25) do
      max_frame = StreamDoctor.Probe.Video.Bar.max_frame()

      Enum.map(range, fn i ->
        pts = milliseconds(1400) + div(i * Membrane.Time.second(), fps)
        {:video_frame_received, rem(i, max_frame), pts}
      end)
    end

    defp audio_recv(range, shift_ms \\ 0) do
      max_symbol = StreamDoctor.Probe.Audio.Tone.max_symbol()

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
      # 130 s of stream; the audio counter wraps at 122.9 s
      assert drift(av_events(130)) == 0
      report = Metric.AvDrift.report(run(Metric.AvDrift, [], av_events(130)))
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
      max = StreamDoctor.Probe.Video.Bar.max_frame()
      Enum.map(numbers, &{:video_frame_received, rem(&1, max), milliseconds(0)})
    end

    defp report(events), do: Metric.Frames.report(run(Metric.Frames, [], events))

    defp video_order(events), do: report(events).video

    test "frames arriving in order report no fault" do
      assert %{
               reordered: %{count: 0, max_depth: nil, permutations: []},
               missing: %{count: 0, gaps: []},
               duplicated: %{count: 0, repeats: []}
             } = video_order(frames(0..99))
    end

    test "a swapped pair counts once" do
      assert %{reordered: %{count: 1, max_depth: 1, permutations: [[12, 11, 13]]}} =
               video_order(frames([10, 12, 11, 13]))
    end

    test "a frame displaced over several others counts once, not once per frame it passed" do
      assert %{reordered: %{count: 1, max_depth: 2, permutations: [[13, 11, 12, 14]]}} =
               video_order(frames([10, 13, 11, 12, 14]))
    end

    test "a permutation follows a descent however long it runs" do
      descending = [1_000 | Enum.to_list(999..900//-1)]

      assert %{reordered: %{permutations: [permutation]}} = video_order(frames(descending))
      assert length(permutation) == length(descending)
    end

    test "a frame displaced over several others is late, not lost" do
      assert %{missing: %{count: 0, gaps: []}, duplicated: %{count: 0}} =
               video_order(frames([10, 13, 11, 12, 14]))
    end

    test "gaps are not reordering" do
      assert %{reordered: %{count: 0}, missing: %{count: 47, gaps: [[3, 49]]}} =
               video_order(frames([0, 1, 2, 50, 51]))
    end

    test "repeated numbers are not reordering" do
      assert %{reordered: %{count: 0}, duplicated: %{count: 2, repeats: [[5, 1], [6, 1]]}} =
               video_order(frames([5, 5, 6, 6, 7]))
    end

    test "a single missing frame is written as one number" do
      assert %{missing: %{count: 1, gaps: [[2]]}} = video_order(frames([0, 1, 3, 4]))
    end

    test "separate outages are listed separately" do
      assert %{missing: %{count: 15, gaps: [[3, 9], [12, 19]]}} =
               video_order(frames([0, 1, 2, 10, 11, 20, 21]))
    end

    test "a long outage is one run, not thousands of numbers" do
      assert %{missing: %{count: 4998, gaps: [[2, 4999]]}} = video_order(frames([0, 1, 5000]))
    end

    test "a hole still open when the stream ends is counted missing" do
      assert %{missing: %{count: 8, gaps: [[12, 19]]}} = video_order(frames([10, 11, 20]))
    end

    test "nothing below the first frame seen is missing" do
      assert %{missing: %{count: 0, gaps: []}} = video_order(frames([100, 101, 102]))
    end

    test "a frame below the first one seen is a late join, not a duplicate" do
      assert %{duplicated: %{count: 0}, missing: %{count: 0}} =
               video_order(frames([10, 11, 9, 12]))
    end

    test "a number far below the join does not move the join point" do
      assert %{duplicated: %{count: 2, repeats: [[3, 1], [4, 1]]}, missing: %{count: 0}} =
               video_order(frames([100, 101, 3, 4, 102]))
    end

    test "a frozen frame is one entry with many repeats" do
      assert %{duplicated: %{count: 3, repeats: [[7, 3]]}} = video_order(frames([7, 7, 7, 7, 8]))
    end

    test "two frames repeating different numbers of times keep their own counts" do
      assert %{duplicated: %{count: 5, repeats: [[5, 2], [6, 3]]}} =
               video_order(frames([5, 5, 5, 6, 6, 6, 6]))
    end

    test "the same number repeating after another frame starts a second run" do
      assert %{duplicated: %{count: 3, repeats: [[5, 1], [6, 1], [5, 1]]}} =
               video_order(frames([5, 5, 6, 6, 5]))
    end

    test "a replayed run shows up as duplicates and as one deep reordering" do
      assert %{
               reordered: %{count: 1, max_depth: 2},
               duplicated: %{count: 3, repeats: [[1, 1], [2, 1], [3, 1]]}
             } = video_order(frames([0, 1, 2, 3, 1, 2, 3, 4]))
    end

    test "a frame arriving after its gap settled is counted as a duplicate too" do
      assert %{missing: %{count: 78}, duplicated: %{count: 1, repeats: [[1, 1]]}} =
               video_order(frames([0, 40, 80, 1]))
    end

    test "a truncated list keeps the newest entries and still totals correctly" do
      assert %{missing: %{count: 88, gaps: gaps}} =
               video_order(frames(Enum.flat_map(0..11, &[&1 * 10, &1 * 10 + 1])))

      assert length(gaps) == 10
      assert Enum.sum(Enum.map(gaps, fn [from, to] -> to - from + 1 end)) < 88
      assert List.last(gaps) == [102, 109]
      refute [2, 9] in gaps
    end

    test "an in-order run across the counter wrap reports nothing" do
      max = StreamDoctor.Probe.Video.Bar.max_frame()

      assert %{
               reordered: %{count: 0},
               missing: %{count: 0},
               duplicated: %{count: 0}
             } = video_order(frames(0..(max + 500)))
    end

    test "reordering across the counter wrap is still detected" do
      max = StreamDoctor.Probe.Video.Bar.max_frame()
      unwrapped = [max, max - 1, max + 1]

      assert %{reordered: %{count: 1, max_depth: 1, permutations: [^unwrapped]}} =
               video_order(frames([max - 2, max, max - 1, max + 1]))
    end

    test "a gap across the counter wrap is one run" do
      max = StreamDoctor.Probe.Video.Bar.max_frame()
      run = [max, max + 4]

      assert %{missing: %{count: 5, gaps: [^run]}} =
               video_order(frames([max - 2, max - 1, max + 5]))
    end

    test "a repeat across the counter wrap is still a duplicate" do
      max = StreamDoctor.Probe.Video.Bar.max_frame()

      assert %{duplicated: %{count: 1, repeats: [[^max, 1]]}} =
               video_order(frames([max - 1, max, max, max + 1]))
    end

    test "decode order instead of display order shows up as a repeating permutation" do
      assert %{
               reordered: %{
                 count: 3,
                 max_depth: 2,
                 permutations: [[3, 1, 2, 6], [6, 4, 5, 9], [9, 7, 8]]
               }
             } = video_order(frames([0, 3, 1, 2, 6, 4, 5, 9, 7, 8]))
    end

    test "a reordering still open when the stream ends is still reported" do
      assert %{reordered: %{permutations: [[13, 12]]}} = video_order(frames([10, 11, 13, 12]))
    end

    test "a frame that jumped far ahead does not drag its distance into the permutation" do
      assert %{reordered: %{max_depth: 99, permutations: [[102, 3, 103]]}} =
               video_order(frames([100, 101, 102, 3, 103, 104]))
    end

    test "the deepest descent is the one reported" do
      assert %{reordered: %{count: 2, max_depth: 50}, missing: %{count: 117}} =
               video_order(frames([100, 90, 200, 150, 210]))
    end

    test "a frame without a pts still counts" do
      events = [{:video_frame_received, 7, nil}, {:video_frame_received, 9, nil}]

      assert %{missing: %{count: 1, gaps: [[8]]}} = video_order(events)
    end

    test "nothing is reported before the first frame" do
      assert %{
               reordered: %{count: nil, max_depth: nil, permutations: []},
               missing: %{count: nil, gaps: []},
               duplicated: %{count: nil, repeats: []}
             } = video_order([])

      assert %{reordered: %{count: nil}} = video_order([{:streamer_started, :missed}])
    end

    test "audio and lifecycle events leave the report alone" do
      events = [
        {:video_frame_received, 1, nil},
        {:audio_symbol_received, 9, milliseconds(0)},
        {:streamer_started, :missed},
        {:first_frame_arrived, 1},
        {:video_frame_received, 2, nil}
      ]

      assert %{
               reordered: %{count: 0},
               missing: %{count: 0},
               duplicated: %{count: 0}
             } = video_order(events)
    end
  end

  describe "Frames, audio track" do
    defp symbols(numbers) do
      max = StreamDoctor.Probe.Audio.Tone.max_symbol()
      Enum.map(numbers, &{:audio_symbol_received, rem(&1, max), milliseconds(0)})
    end

    defp symbol_order(events), do: report(events).audio

    test "symbols arriving in order report no fault" do
      assert %{
               reordered: %{count: 0, max_depth: nil, permutations: []},
               missing: %{count: 0, gaps: []},
               duplicated: %{count: 0, repeats: []}
             } = symbol_order(symbols(0..99))
    end

    test "the symbol counter wrapping is unwrapped, not read as loss" do
      max = StreamDoctor.Probe.Audio.Tone.max_symbol()

      assert %{reordered: %{count: 0}, missing: %{count: 0}} =
               symbol_order(symbols((max - 50)..(max + 50)))
    end

    test "a symbol that never arrived is reported missing" do
      assert %{missing: %{count: 1, gaps: [[12]]}} = symbol_order(symbols([10, 11, 13, 14]))
    end

    test "a symbol arriving twice is reported duplicated" do
      assert %{duplicated: %{count: 1, repeats: [[5, 1]]}} = symbol_order(symbols([5, 6, 5]))
    end

    test "video and lifecycle events leave the report alone" do
      events = [
        {:audio_symbol_received, 1, milliseconds(0)},
        {:video_frame_received, 9, nil},
        {:streamer_started, :missed},
        {:first_frame_arrived, 1},
        {:audio_symbol_received, 2, milliseconds(30)}
      ]

      assert %{
               reordered: %{count: 0},
               missing: %{count: 0},
               duplicated: %{count: 0}
             } = symbol_order(events)
    end

    test "nothing is reported before the first symbol" do
      assert %{
               reordered: %{count: nil, max_depth: nil, permutations: []},
               missing: %{count: nil, gaps: []},
               duplicated: %{count: nil, repeats: []}
             } = symbol_order([])
    end

    test "each track keeps its own counters in one fold" do
      events = frames([10, 12, 11, 13]) ++ symbols([20, 22])

      assert %{
               video: %{reordered: %{count: 1}, missing: %{count: 0}},
               audio: %{reordered: %{count: 0}, missing: %{count: 1, gaps: [[21]]}}
             } = report(events)
    end
  end

  describe "TimeToFirstFrame" do
    defp ttff(events),
      do: Metric.TimeToFirstFrame.report(run(Metric.TimeToFirstFrame, [], events))

    defp watching(at), do: {:streamer_started, {:watching, at}}

    defp missed, do: {:streamer_started, :missed}

    defp arrived(at), do: {:first_frame_arrived, at}

    test "measures from the streamer starting to the first frame" do
      assert %{status: :measured, ms: 1_900} = ttff([watching(1_500), arrived(3_400)])
    end

    test "a viewer that started after the streamer does not measure" do
      assert %{status: :missed_first_frame, ms: nil} = ttff([missed(), arrived(3_400)])
    end

    test "a frame older than the streamer is rejected when the start is known first" do
      assert %{status: :missed_first_frame, ms: nil} = ttff([watching(5_000), arrived(2_000)])
    end

    test "a frame older than the streamer is rejected when the frame arrives first" do
      assert %{status: :missed_first_frame, ms: nil} = ttff([arrived(2_000), watching(5_000)])
    end

    test "a frame without a streamer has nothing to measure from" do
      assert %{status: :no_streamer, ms: nil} = ttff([arrived(1_200)])
    end

    test "a viewer that joined a running stream says so before any frame arrives" do
      assert %{status: :missed_first_frame, ms: nil} = ttff([missed()])
    end

    test "reports waiting_for_the_first_frame until a frame arrives" do
      assert %{status: :waiting_for_the_first_frame, ms: nil} = ttff([])
      assert %{status: :waiting_for_the_first_frame, ms: nil} = ttff([watching(1_500)])
    end

    test "a republished streamer is measured from its own start" do
      assert %{status: :measured, ms: 2_000} =
               ttff([watching(0), watching(30_000), arrived(32_000)])
    end

    test "a viewer watching when the second streamer started measures that one" do
      assert %{status: :measured, ms: 2_000} = ttff([missed(), watching(30_000), arrived(32_000)])
    end

    test "a streamer restart does not move a finished measurement" do
      events = [watching(1_500), arrived(3_400), watching(9_000)]

      assert %{status: :measured, ms: 1_900} = ttff(events)
    end

    test "a second frame cannot arrive" do
      assert_raise RuntimeError, ~r/twice/, fn ->
        ttff([watching(1_500), arrived(3_400), arrived(9_000)])
      end
    end

    test "a missed start cannot follow another event" do
      assert_raise RuntimeError, ~r/viewer is created/, fn ->
        ttff([watching(1_500), missed()])
      end
    end
  end

  describe "AvailabilityLatency" do
    defp latency(events) do
      Metric.AvailabilityLatency.report(run(Metric.AvailabilityLatency, [], events))
    end

    defp frame(number, segment, sent_at) do
      pts = milliseconds(number * 40)

      [
        {:video_frame_sent, number, sent_at},
        {:video_chunk_received, segment, pts},
        {:video_frame_received, number, pts}
      ]
    end

    test "a segment is measured from when its frame was sent to when it was listed" do
      listed = {:segment_available, 37, 3000}
      measured = %{status: :measured, ms: 500, latest_samples: [500]}

      assert latency(frame(60, 37, 2500) ++ [listed]) == measured
      assert latency([listed | frame(60, 37, 2500)]) == measured
    end

    test "each segment is measured on the last of its frames to be sent" do
      events =
        frame(58, 37, 2420) ++
          [{:segment_available, 37, 3000}] ++
          frame(60, 37, 2500) ++
          frame(59, 37, 2460) ++
          frame(120, 38, 4500) ++ [{:segment_available, 38, 5100}]

      assert %{ms: 600, latest_samples: [600, 500]} = latency(events)
    end

    test "a frame is matched to its segment by PTS, not by the order of arrival" do
      events = [
        {:video_frame_sent, 60, 2500},
        {:video_frame_sent, 61, 2540},
        {:video_chunk_received, 37, milliseconds(2400)},
        {:video_chunk_received, 38, milliseconds(2440)},
        {:video_frame_received, 61, milliseconds(2440)},
        {:video_frame_received, 60, milliseconds(2400)},
        {:segment_available, 37, 3000}
      ]

      assert %{latest_samples: [500]} = latency(events)
    end

    test "a segment that was only listed or only decoded yields no sample" do
      events = [{:segment_available, 36, 3000} | frame(60, 37, 2500)]

      assert latency(events) == %{status: :waiting, ms: nil, latest_samples: []}
    end

    test "a frame sent before the viewer attached yields no sample" do
      [_sent | received] = frame(60, 37, 2500)

      assert %{status: :waiting} = latency(received ++ [{:segment_available, 37, 3000}])
    end

    test "a restarted streamer is measured on its own frames" do
      events =
        frame(60, 37, 2500) ++
          [{:segment_available, 37, 3000}] ++
          frame(60, 52, 42_500) ++ [{:segment_available, 52, 43_200}]

      assert %{latest_samples: [700, 500]} = latency(events)
    end

    test "only the newest samples are kept" do
      segments =
        Enum.flat_map(1..60, &(frame(&1, &1, &1 * 1000) ++ [{:segment_available, &1, &1 * 1001}]))

      report = latency(segments)

      assert report.latest_samples == Enum.to_list(60..51//-1)
      assert report.ms == 36
    end
  end

  describe "PlaylistRequests" do
    defp requests(events) do
      Metric.PlaylistRequests.report(run(Metric.PlaylistRequests, [], events))
    end

    test "nothing is reported before the first reload" do
      assert requests([]) == %{
               requests: 0,
               failed: 0,
               timeouts: 0,
               statuses: %{},
               ms: nil,
               latest_samples: []
             }
    end

    test "answers are counted per status and anything but a 200 has failed" do
      events = [
        {:playlist_requested, 200, 10},
        {:playlist_requested, 404, 30},
        {:playlist_requested, 200, 20}
      ]

      assert requests(events) == %{
               requests: 3,
               failed: 1,
               timeouts: 0,
               statuses: %{200 => 2, 404 => 1},
               ms: 20,
               latest_samples: [20, 30, 10]
             }
    end

    test "a timeout and a connection error fail without a status or a time" do
      events = [
        {:playlist_requested, 200, 10},
        {:playlist_requested, :timeout, 5000},
        {:playlist_requested, :error, 1}
      ]

      assert requests(events) == %{
               requests: 3,
               failed: 2,
               timeouts: 1,
               statuses: %{200 => 1},
               ms: 10,
               latest_samples: [10]
             }
    end

    test "only the newest samples are kept" do
      report = requests(Enum.map(1..60, &{:playlist_requested, 200, &1}))

      assert report.requests == 60
      assert report.latest_samples == Enum.to_list(60..51//-1)
      assert report.ms == 36
    end

    test "the report encodes to JSON" do
      assert JSON.encode!(requests([{:playlist_requested, 200, 10}])) =~ ~s("200":1)
    end
  end

  describe "PlaylistAge" do
    defp age(events) do
      Metric.PlaylistAge.report(run(Metric.PlaylistAge, [], events))
    end

    defp read(at, {newest, target_duration_ms}) do
      {:playlist_read, at, %{newest: newest, target_duration_ms: target_duration_ms}}
    end

    defp read(at, state) do
      {:playlist_read, at, state}
    end

    test "nothing is reported before the playlist is read" do
      assert age([]) == %{
               target_duration_ms: nil,
               age_ms: nil,
               max_age_ms: nil,
               stale: 0,
               latest_samples: []
             }
    end

    test "a playlist updated on time is never stale" do
      events = [read(0, {5, 2000}), read(1900, {5, 2000}), read(2100, {6, 2000})]

      assert age(events ++ [read(3000, {6, 2000})]) == %{
               target_duration_ms: 2000,
               age_ms: 900,
               max_age_ms: 2100,
               stale: 0,
               latest_samples: [2100]
             }
    end

    test "a playlist is stale past one and a half target durations, once per stall" do
      events = [
        read(0, {5, 2000}),
        read(3000, {5, 2000}),
        read(3001, {5, 2000}),
        read(4000, {5, 2000})
      ]

      assert %{stale: 1, age_ms: 4000, max_age_ms: 4000, latest_samples: []} = age(events)

      assert %{stale: 2, age_ms: 3500, max_age_ms: 4500, latest_samples: [4500]} =
               age(events ++ [read(4500, {6, 2000}), read(8000, {6, 2000})])
    end

    test "a stall nobody read the playlist during is counted when the segment shows up" do
      assert %{stale: 1, age_ms: 0, latest_samples: [9000]} =
               age([read(0, {5, 2000}), read(9000, {6, 2000})])
    end

    test "an unreadable playlist keeps ageing" do
      events = [read(0, {5, 2000}), read(3500, :unreadable)]

      assert %{stale: 1, age_ms: 3500} = age(events)
    end

    test "an ended playlist stops ageing" do
      events = [read(0, {5, 2000}), read(1000, :ended), read(60_000, :ended)]

      assert %{stale: 0, age_ms: 0, max_age_ms: 0} = age(events)
    end

    test "only the newest samples are kept" do
      events = Enum.map(0..20, &read(&1 * &1, {&1, 2000}))

      assert age(events).latest_samples == Enum.map(20..11//-1, &(2 * &1 - 1))
    end
  end

  describe "MediaSequence" do
    defp sequence(events) do
      Metric.MediaSequence.report(run(Metric.MediaSequence, [], events))
    end

    defp listed(numbers, name \\ "seg") do
      listing = %{
        media_sequence: Enum.min(numbers),
        newest: Enum.max(numbers),
        target_duration_ms: 2000,
        uris: Map.new(numbers, &{&1, "#{name}#{&1}.ts"})
      }

      {:playlist_read, 0, listing}
    end

    @clean %{regressed: 0, skipped: 0, replaced: 0, withdrawn: 0, latest_faults: []}

    test "a sliding window that keeps its segments reports no fault" do
      assert sequence([listed(3..5), listed(3..6), listed(4..6), listed(5..7)]) == @clean
    end

    test "a window that jumps to the segment right after the newest skips nothing" do
      assert sequence([listed(3..5), listed(6..8)]) == @clean
    end

    test "segments the window moved past unseen are skipped" do
      assert sequence([listed(3..5), listed(9..11)]) ==
               %{@clean | skipped: 3, latest_faults: [%{fault: :skipped, from: 6, to: 8}]}
    end

    test "a media sequence that went down has regressed, and is compared from there" do
      assert sequence([listed(7..9), listed(0..2), listed(1..3)]) ==
               %{@clean | regressed: 1, latest_faults: [%{fault: :regressed, from: 7, to: 0}]}
    end

    test "a segment whose URI changed under its number was replaced" do
      events = [listed(3..5), {:playlist_read, 0, put_in(elem(listed(3..6), 2).uris[4], "x.ts")}]

      assert sequence(events) ==
               %{@clean | replaced: 1, latest_faults: [%{fault: :replaced, from: 4, to: 4}]}
    end

    test "segments gone from the end of the playlist were withdrawn" do
      assert sequence([listed(3..7), listed(3..5)]) ==
               %{@clean | withdrawn: 2, latest_faults: [%{fault: :withdrawn, from: 6, to: 7}]}
    end

    test "an unreadable or ended playlist is not compared" do
      events = [listed(3..5), {:playlist_read, 0, :unreadable}, {:playlist_read, 0, :ended}]

      assert sequence(events ++ [listed(4..6)]) == @clean
    end

    test "only the newest faults are kept, newest first" do
      report = sequence(Enum.map(0..12, &listed([&1 * 3])))

      assert report.skipped == 24
      assert length(report.latest_faults) == 10
      assert hd(report.latest_faults) == %{fault: :skipped, from: 34, to: 35}
    end

    test "the report encodes to JSON" do
      assert JSON.encode!(sequence([listed(3..5), listed(9..11)])) =~ ~s("fault":"skipped")
    end
  end

  describe "RtmpPublish" do
    defp publish(events) do
      Metric.RtmpPublish.report(run(Metric.RtmpPublish, [], events))
    end

    @started {:streamer_started, {:watching, 1000}}

    test "a publish the ingest has not accepted yet is connecting" do
      assert publish([@started]) == %{status: :connecting, connect_ms: nil}
    end

    test "an accepted publish reports how long the ingest took" do
      assert publish([@started, {:streamer_connected, 1250}]) ==
               %{status: :connected, connect_ms: 250}
    end

    test "a streamer failing before the ingest accepted it has failed" do
      assert publish([@started, :streamer_failed]) == %{status: :failed, connect_ms: nil}
    end

    test "a streamer failing after the ingest accepted it was dropped" do
      assert publish([@started, {:streamer_connected, 1250}, :streamer_failed]) ==
               %{status: :dropped, connect_ms: 250}
    end
  end
end
