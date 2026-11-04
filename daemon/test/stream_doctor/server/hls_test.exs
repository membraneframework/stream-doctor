defmodule StreamDoctor.Server.HLSTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias StreamDoctor.Metric
  alias StreamDoctor.Server.HLS

  @base "http://cdn.example/a/master.m3u8"
  @slow_response 60

  @empty """
  #EXTM3U
  #EXT-X-VERSION:3
  #EXT-X-TARGETDURATION:2
  """

  @segments """
  #EXTM3U
  #EXT-X-VERSION:3
  #EXT-X-TARGETDURATION:2
  #EXTINF:2.0,
  seg0.ts
  """

  @master """
  #EXTM3U
  #EXT-X-STREAM-INF:BANDWIDTH=100
  sub/index.m3u8
  """

  @uriless_master """
  #EXTM3U
  #EXT-X-STREAM-INF:BANDWIDTH=100
  """

  @self_referencing_master """
  #EXTM3U
  #EXT-X-STREAM-INF:BANDWIDTH=100
  master.m3u8
  """

  defp media(target, sequence, durations) do
    segments =
      durations
      |> Enum.with_index(sequence)
      |> Enum.map_join(fn {duration, number} -> "#EXTINF:#{duration},\nseg#{number}.ts\n" end)

    """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:#{target}
    #EXT-X-MEDIA-SEQUENCE:#{sequence}
    """ <> segments
  end

  defp serve(responses) do
    {:ok, script} = Agent.start_link(fn -> {responses, []} end)

    Req.Test.stub(:http, fn conn ->
      asked = {conn.request_path, Metric.now_ms()}

      response =
        Agent.get_and_update(script, fn
          {[last], seen} -> {last, {[last], [asked | seen]}}
          {[next | rest], seen} -> {next, {rest, [asked | seen]}}
        end)

      case response.(conn.request_path) do
        {:ok, body} -> Req.Test.text(conn, body)
        {:error, status} -> Plug.Conn.send_resp(conn, status, "")
      end
    end)

    script
  end

  defp requested(script), do: script |> asked() |> Enum.map(fn {path, _at} -> path end)

  defp gaps(script) do
    script |> asked() |> Enum.map(fn {_path, at} -> at end) |> Enum.chunk_every(2, 1, :discard)
  end

  defp asked(script), do: script |> Agent.get(fn {_rest, seen} -> seen end) |> Enum.reverse()

  defp watch(url, timeout \\ 1_000) do
    test = self()

    {pid, ref} =
      spawn_monitor(fn ->
        receive do: (:go -> :ok)
        HLS.watch(url, timeout, &send(test, &1))
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    Req.Test.allow(:http, self(), pid)
    send(pid, :go)
    ref
  end

  defp assert_raised(ref, pattern) do
    capture_log(fn ->
      assert_receive {:DOWN, ^ref, :process, _pid, {%RuntimeError{message: message}, _stack}},
                     1_000

      assert message =~ pattern
    end)
  end

  test "the segment is stamped when it was asked for, not when the answer arrived" do
    serve([
      fn _path ->
        Process.sleep(@slow_response)
        {:ok, @segments}
      end
    ])

    asked_at = Metric.now_ms()
    watch(@base)

    assert_receive {:first_frame_arrived, at}, 1_000
    answered_at = Metric.now_ms()

    assert at >= asked_at
    assert answered_at - at >= @slow_response
  end

  test "keeps polling through a playlist that is not served yet" do
    script =
      serve([
        fn _path -> {:error, 404} end,
        fn _path -> {:error, 404} end,
        fn _path -> {:ok, @segments} end
      ])

    watch(@base)

    assert_receive {:first_frame_arrived, _at}, 1_000
    assert requested(script) == List.duplicate("/a/master.m3u8", 3)
  end

  test "a master playlist is followed into its first variant" do
    script =
      serve([
        fn "/a/master.m3u8" -> {:ok, @master} end,
        fn "/a/sub/index.m3u8" -> {:ok, @segments} end
      ])

    watch(@base)

    assert_receive {:first_frame_arrived, _at}, 1_000
    assert requested(script) == ["/a/master.m3u8", "/a/sub/index.m3u8"]
  end

  test "a failing variant sends the poller back to the master playlist" do
    script =
      serve([
        fn "/a/master.m3u8" -> {:ok, @master} end,
        fn "/a/sub/index.m3u8" -> {:error, 404} end,
        fn "/a/master.m3u8" -> {:ok, @master} end,
        fn "/a/sub/index.m3u8" -> {:ok, @segments} end
      ])

    watch(@base)

    assert_receive {:first_frame_arrived, _at}, 1_000

    assert requested(script) == [
             "/a/master.m3u8",
             "/a/sub/index.m3u8",
             "/a/master.m3u8",
             "/a/sub/index.m3u8"
           ]
  end

  @tag timeout: 1_000
  test "a master playlist that points at itself does not spin" do
    serve([fn _path -> {:ok, @self_referencing_master} end])

    assert_raised(watch(@base, 20), "no segments yet")
  end

  @tag timeout: 1_000
  test "a stream inf with no URI line does not spin" do
    serve([fn _path -> {:ok, @uriless_master} end])

    assert_raised(watch(@base, 20), "no segments yet")
  end

  test "a playlist that never appears raises past the deadline" do
    serve([fn _path -> {:error, 404} end])

    assert_raised(watch(@base, 5), "not available")
  end

  test "a master playlist whose variant never lists a segment raises past the deadline" do
    serve([
      fn
        "/a/master.m3u8" -> {:ok, @master}
        "/a/sub/index.m3u8" -> {:ok, @empty}
      end
    ])

    assert_raised(watch(@base, 20), "no segments yet")
  end

  test "the segments listed before watching began count towards the timeline but are not timed" do
    serve([
      fn _path -> {:ok, media(1, 0, [1.0, 1.0])} end,
      fn _path -> {:ok, media(1, 0, [1.0, 1.0, 2.0])} end
    ])

    watch(@base)

    assert_receive {:first_frame_arrived, _at}, 1_000

    assert_receive {:media_available, media_end, _at}, 1_000
    assert media_end == Membrane.Time.seconds(4)

    refute_receive {:media_available, _media_end, _at}, 300
  end

  test "a media playlist with CRLF line endings is read, not crashed on" do
    serve([fn _path -> {:ok, String.replace(media(1, 0, [1.0, 1.0]), "\n", "\r\n")} end])

    watch(@base)

    assert_receive {:first_frame_arrived, _at}, 1_000
    refute_receive {:DOWN, _ref, :process, _pid, _reason}, 300
  end

  test "segments that left the playlist window are not reported again" do
    serve([
      fn _path -> {:ok, media(1, 0, [1.0, 1.0])} end,
      fn _path -> {:ok, media(1, 1, [1.0, 1.0])} end
    ])

    watch(@base)

    assert_receive {:media_available, media_end, _at}, 2_000
    assert media_end == Membrane.Time.seconds(3)

    refute_receive {:media_available, _media_end, _at}, 300
  end

  test "a reload that finds several new segments reports only the newest" do
    serve([
      fn _path -> {:ok, media(1, 0, [1.0])} end,
      fn _path -> {:ok, media(1, 0, [1.0, 1.0, 1.0])} end
    ])

    watch(@base)

    assert_receive {:media_available, media_end, _at}, 2_000
    assert media_end == Membrane.Time.seconds(3)

    refute_receive {:media_available, _media_end, _at}, 300
  end

  test "a window that moved past an unseen segment breaks the timeline" do
    serve([
      fn _path -> {:ok, media(1, 0, [1.0])} end,
      fn _path -> {:ok, media(1, 2, [1.0])} end
    ])

    watch(@base)

    assert_receive {:timeline_broken, :window_gap}, 2_000
  end

  test "a discontinuity breaks the timeline" do
    serve([
      fn _path -> {:ok, media(1, 0, [1.0]) <> "#EXT-X-DISCONTINUITY\n#EXTINF:1.0,\nseg1.ts\n"} end
    ])

    watch(@base)

    assert_receive {:timeline_broken, :discontinuity}, 1_000
    refute_receive {:media_available, _media_end, _at}, 100
  end

  test "a playlist that fails once the watch is running is retried, not given up on" do
    serve([
      fn _path -> {:ok, media(1, 0, [1.0])} end,
      fn _path -> {:error, 503} end,
      fn _path -> {:ok, media(1, 0, [1.0, 1.0])} end
    ])

    watch(@base, 500)

    assert_receive {:media_available, media_end, _at}, 1_000
    assert media_end == Membrane.Time.seconds(2)
  end

  test "a discontinuity appearing mid-stream breaks the timeline" do
    serve([
      fn _path -> {:ok, media(1, 0, [1.0])} end,
      fn _path -> {:ok, media(1, 0, [1.0]) <> "#EXT-X-DISCONTINUITY\n#EXTINF:1.0,\nseg1.ts\n"} end
    ])

    watch(@base)

    assert_receive {:timeline_broken, :discontinuity}, 1_000
    refute_receive {:media_available, _media_end, _at}, 300
  end

  test "a playlist whose first load already dropped segments reports a missed start" do
    serve([fn _path -> {:ok, media(1, 3, [1.0])} end])

    watch(@base)

    assert_receive {:first_frame_arrived, _at}, 1_000
    assert_receive {:timeline_broken, :missed_start}, 1_000
  end

  test "a broken timeline stops the polling" do
    script =
      serve([
        fn _path -> {:ok, media(1, 0, [1.0])} end,
        fn _path ->
          {:ok, media(1, 0, [1.0]) <> "#EXT-X-DISCONTINUITY\n#EXTINF:1.0,\nseg1.ts\n"}
        end,
        fn _path -> {:ok, media(1, 0, [1.0, 1.0, 1.0])} end
      ])

    watch(@base)

    assert_receive {:timeline_broken, :discontinuity}, 1_000
    Process.sleep(1_200)

    assert length(requested(script)) == 2
  end

  test "a segment is caught at the polling interval, then reloads follow the target duration" do
    script =
      serve([
        fn _path -> {:ok, media(1, 0, [1.0])} end,
        fn _path -> {:ok, media(1, 0, [1.0, 1.0])} end
      ])

    watch(@base, 2_000)

    assert_receive {:media_available, _media_end, _at}, 1_000
    Process.sleep(1_800)

    assert [sync, after_change, after_no_change] =
             script |> gaps() |> Enum.take(3) |> Enum.map(fn [from, to] -> to - from end)

    assert sync in 150..400
    assert after_change in 950..1_200
    assert after_no_change in 450..700
  end

  test "a playlist that never changes stops being polled at the sync interval" do
    script = serve([fn _path -> {:ok, media(1, 0, [1.0])} end])

    watch(@base, 2_000)

    assert_receive {:first_frame_arrived, _at}, 1_000
    Process.sleep(3_000)

    assert [from, to] = script |> gaps() |> List.last()
    assert (to - from) in 450..700
  end
end
