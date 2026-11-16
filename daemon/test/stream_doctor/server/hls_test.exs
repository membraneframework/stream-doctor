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

  @uriless_master """
  #EXTM3U
  #EXT-X-STREAM-INF:BANDWIDTH=100
  """

  @self_referencing_master """
  #EXTM3U
  #EXT-X-STREAM-INF:BANDWIDTH=100
  master.m3u8
  """

  defp serve(responses) do
    {:ok, script} = Agent.start_link(fn -> {responses, []} end)

    Req.Test.stub(:http, fn conn ->
      response =
        Agent.get_and_update(script, fn
          {[last], seen} -> {last, {[last], [conn.request_path | seen]}}
          {[next | rest], seen} -> {next, {rest, [conn.request_path | seen]}}
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
    at = HLS.await_first_segment(@base, 1_000)
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

    HLS.await_first_segment(@base, 1_000)

    assert requested(script) == List.duplicate("/a/master.m3u8", 3)
  end

  test "a master playlist is followed into its first variant" do
    script =
      serve([
        fn "/a/master.m3u8" -> {:ok, @master} end,
        fn "/a/sub/index.m3u8" -> {:ok, @segments} end
      ])

    HLS.await_first_segment(@base, 1_000)

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

    HLS.await_first_segment(@base, 1_000)

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

    assert_raise RuntimeError, ~r/no segments yet/, fn -> HLS.await_first_segment(@base, 20) end
  end

  @tag timeout: 1_000
  test "a stream inf with no URI line does not spin" do
    serve([fn _path -> {:ok, @uriless_master} end])

    assert_raise RuntimeError, ~r/no segments yet/, fn -> HLS.await_first_segment(@base, 20) end
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
end
