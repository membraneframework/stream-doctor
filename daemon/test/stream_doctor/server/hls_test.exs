defmodule StreamDoctor.Server.HLSTest do
  use ExUnit.Case, async: true

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

  @audio_first_master """
  #EXTM3U
  #EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.2"
  audio/index.m3u8
  #EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="avc1.64001e,mp4a.40.2"
  video/index.m3u8
  """

  defp serve(responses) do
    {:ok, script} = Agent.start_link(fn -> {responses, []} end)

    Req.Test.stub(:http, fn conn ->
      asked =
        conn.request_path <> if(conn.query_string == "", do: "", else: "?" <> conn.query_string)

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

  defp requested(script), do: script |> Agent.get(fn {_rest, seen} -> seen end) |> Enum.reverse()

  test "the segment is stamped when it was asked for, not when the answer arrived" do
    serve([
      fn _path ->
        Process.sleep(@slow_response)
        {:ok, @segments}
      end
    ])

    asked_at = Metric.now_ms()

    assert at = HLS.await_first_segment(@base, 1_000)
    assert at >= asked_at and at - asked_at < @slow_response
  end

  test "keeps polling through a playlist that is not served yet" do
    script =
      serve([
        fn _path -> {:error, 404} end,
        fn _path -> {:error, 404} end,
        fn _path -> {:ok, @segments} end
      ])

    HLS.await_first_segment(@base, 1_000)

    assert requested(script) == List.duplicate("/a/master.m3u8", 3)
  end

  test "a variant URI without a query inherits the master playlists token" do
    script =
      serve([
        fn "/a/master.m3u8" -> {:ok, @master} end,
        fn "/a/sub/index.m3u8" -> {:ok, @segments} end
      ])

    HLS.await_first_segment("http://cdn.example/a/master.m3u8?token=abc", 1_000)

    assert requested(script) == ["/a/master.m3u8?token=abc", "/a/sub/index.m3u8?token=abc"]
  end

  test "a master playlist is followed into its first variant that declares video" do
    script =
      serve([
        fn "/a/master.m3u8" -> {:ok, @audio_first_master} end,
        fn "/a/video/index.m3u8" -> {:ok, @segments} end
      ])

    HLS.await_first_segment(@base, 1_000)

    assert requested(script) == ["/a/master.m3u8", "/a/video/index.m3u8"]
  end

  test "a failing variant sends the poller back to the master playlist" do
    script =
      serve([
        fn "/a/master.m3u8" -> {:ok, @master} end,
        fn "/a/sub/index.m3u8" -> {:error, 404} end,
        fn "/a/master.m3u8" -> {:ok, @master} end,
        fn "/a/sub/index.m3u8" -> {:ok, @segments} end
      ])

    HLS.await_first_segment(@base, 1_000)

    assert requested(script) == [
             "/a/master.m3u8",
             "/a/sub/index.m3u8",
             "/a/master.m3u8",
             "/a/sub/index.m3u8"
           ]
  end

  test "a playlist that never appears raises past the deadline" do
    serve([fn _path -> {:error, 404} end])

    assert_raise RuntimeError, ~r/not available/, fn -> HLS.await_first_segment(@base, 5) end
  end

  test "a master playlist whose variant never lists a segment raises past the deadline" do
    serve([
      fn
        "/a/master.m3u8" -> {:ok, @master}
        "/a/sub/index.m3u8" -> {:ok, @empty}
      end
    ])

    assert_raise RuntimeError, ~r/no segments yet/, fn -> HLS.await_first_segment(@base, 20) end
  end

  test "a variant on another host does not inherit the master playlists token" do
    script =
      serve([
        fn _path ->
          {:ok, "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nhttp://other.cdn/v/x.m3u8\n"}
        end,
        fn _path -> {:ok, @segments} end
      ])

    HLS.await_first_segment("http://cdn.example/a/master.m3u8?token=abc", 1_000)

    assert requested(script) == ["/a/master.m3u8?token=abc", "/v/x.m3u8"]
  end

  test "a playlist with CRLF line endings is followed into its variant" do
    script =
      serve([
        fn _path -> {:ok, String.replace(@master, "\n", "\r\n")} end,
        fn _path -> {:ok, @segments} end
      ])

    assert HLS.await_first_segment(@base, 1_000)

    assert requested(script) == ["/a/master.m3u8", "/a/sub/index.m3u8"]
  end
end
