defmodule StreamDoctor.ServerTest do
  use ExUnit.Case, async: false

  alias StreamDoctor.Server

  @moduletag :capture_log

  setup {Req.Test, :set_req_test_to_shared}

  @playlist """
  #EXTM3U
  #EXT-X-VERSION:3
  #EXT-X-TARGETDURATION:2
  #EXTINF:2.0,
  seg0.ts
  """

  test "a viewer keeps receiving when the playlist it has just seen answers 404" do
    test = self()
    {:ok, playlist_requests} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(:http, fn conn ->
      if conn.request_path == "/live.m3u8" do
        case Agent.get_and_update(playlist_requests, &{&1, &1 + 1}) do
          request when request in 1..2 -> Plug.Conn.send_resp(conn, 404, "")
          _first_or_later -> Req.Test.text(conn, @playlist)
        end
      else
        send(test, :segment_requested)
        Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    {:ok, %{id: id}} = Server.start_viewer("http://cdn.example/live.m3u8")
    on_exit(fn -> Server.stop_viewer(id) end)

    # Only the receiver asks for segments, and it does so once it has read the playlist.
    assert_receive :segment_requested, 5_000
    assert {:ok, %{status: :receiving, error: nil}} = Server.viewer(id)
  end
end
