defmodule StreamDoctor.HLS.DescriptionTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.HLS.Description

  setup_all do
    Req.default_options(plug: {Req.Test, :http})
    on_exit(fn -> Req.default_options([]) end)
  end

  @base "http://cdn.example/a/master.m3u8"

  @media_ts """
  #EXTM3U
  #EXT-X-VERSION:3
  #EXT-X-TARGETDURATION:2
  #EXTINF:2.0,
  seg0.ts
  """

  @media_cmaf """
  #EXTM3U
  #EXT-X-VERSION:7
  #EXT-X-TARGETDURATION:2
  #EXT-X-MAP:URI="init.mp4"
  #EXTINF:2.0,
  seg0.m4s
  """

  defp serve(master) do
    Req.Test.stub(:http, fn conn ->
      case conn.request_path do
        "/a/master.m3u8" -> Req.Test.text(conn, master)
        "/a/sub/index.m3u8" -> Req.Test.text(conn, @media_ts)
        "/abs/index.m3u8" -> Req.Test.text(conn, @media_cmaf)
        "/other/index.m3u8" -> Req.Test.text(conn, @media_ts)
        _other -> Plug.Conn.send_resp(conn, 404, "not found")
      end
    end)
  end

  test "a media playlist becomes one synthetic variant" do
    serve(@media_ts)

    assert {:ok, [%{id: 0, uri: @base, container: :mpeg_ts, codecs: nil, tracks: :unknown}]} =
             Description.variants(@base)
  end

  test "EXT-X-MAP marks the variant as cmaf" do
    serve(@media_cmaf)

    assert {:ok, [%{container: :cmaf}]} = Description.variants(@base)
  end

  test "declared attributes are carried through per variant" do
    serve("""
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=985600,AVERAGE-BANDWIDTH=865000,RESOLUTION=640x360,FRAME-RATE=29.97,NAME="360p",CODECS="avc1.64001e,mp4a.40.2"
    sub/index.m3u8
    """)

    assert {:ok,
            [
              %{
                id: 0,
                bandwidth: 985_600,
                average_bandwidth: 865_000,
                resolution: %{width: 640, height: 360},
                frame_rate: 29.97,
                name: "360p",
                codecs: "avc1.64001e,mp4a.40.2",
                tracks: [%{type: :video, profile: :high}, %{type: :audio, profile: :LC}]
              }
            ]} = Description.variants(@base)
  end

  test "variant URIs resolve against the playlist URL" do
    serve("""
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=100
    sub/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=200
    /abs/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=300
    http://cdn.example/index.m3u8
    """)

    assert {:ok,
            [
              %{uri: "http://cdn.example/a/sub/index.m3u8"},
              %{uri: "http://cdn.example/abs/index.m3u8"},
              %{uri: "http://cdn.example/index.m3u8"}
            ]} = Description.variants(@base)
  end

  test "each variant container comes from its own media playlist" do
    serve("""
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=100
    sub/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=200
    /abs/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=300
    http://cdn.example/other/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=400
    missing/index.m3u8
    """)

    assert {:ok,
            [
              %{container: :mpeg_ts},
              %{container: :cmaf},
              %{container: :mpeg_ts},
              %{container: nil}
            ]} = Description.variants(@base)
  end

  test "a malformed playlist reports an error" do
    serve("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=abc\na.m3u8\n")

    assert {:error, _reason} = Description.variants(@base)
  end

  test "a missing playlist reports the status" do
    serve(@media_ts)

    assert {:error, "http://cdn.example/nope.m3u8: HTTP 404"} =
             Description.variants("http://cdn.example/nope.m3u8")
  end
end
