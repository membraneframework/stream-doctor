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

  @fixtures "test/fixtures/hls"

  defp serve(master, media \\ %{}) do
    Req.Test.stub(:http, fn conn ->
      case conn.request_path do
        "/a/master.m3u8" -> Req.Test.text(conn, master)
        "/a/" <> path when is_map_key(media, path) -> send_media(conn, media[path])
        "/a/sub/index.m3u8" -> Req.Test.text(conn, @media_ts)
        "/abs/index.m3u8" -> Req.Test.text(conn, @media_cmaf)
        "/other/index.m3u8" -> Req.Test.text(conn, @media_ts)
        _other -> Plug.Conn.send_resp(conn, 404, "not found")
      end
    end)
  end

  defp send_media(conn, "#EXTM3U" <> _rest = playlist) do
    Req.Test.text(conn, playlist)
  end

  defp send_media(conn, fixture) do
    Plug.Conn.send_resp(conn, 200, File.read!(Path.join(@fixtures, fixture)))
  end

  @video %{type: :video, codec: :h264, profile: :main, level: "1.1"}
  @audio %{type: :audio, codec: :aac, profile: :LC, level: nil}

  test "a media playlist becomes one synthetic variant" do
    serve(@media_ts)

    assert {:ok, [%{id: 0, uri: @base, container: :mpeg_ts, codecs: nil, tracks: :unknown}]} =
             Description.variants(@base)
  end

  test "a media playlist has its tracks read from the newest mpeg-ts segment" do
    serve(@media_ts <> "#EXTINF:2.0,\nseg1.ts\n", %{"seg1.ts" => "av.ts"})

    assert {:ok, [%{container: :mpeg_ts, codecs: nil, tracks: [@video, @audio]}]} =
             Description.variants(@base)
  end

  test "a media playlist has its tracks read from the cmaf init section" do
    serve(@media_cmaf, %{"init.mp4" => "init.mp4"})

    assert {:ok, [%{container: :cmaf, codecs: nil, tracks: [@video, @audio]}]} =
             Description.variants(@base)
  end

  test "a variant without CODECS has its tracks read from its media" do
    serve(
      """
      #EXTM3U
      #EXT-X-STREAM-INF:BANDWIDTH=100
      muxed.m3u8
      """,
      %{"muxed.m3u8" => @media_ts, "seg0.ts" => "av.ts"}
    )

    assert {:ok, [%{codecs: nil, tracks: [@video, @audio]}]} = Description.variants(@base)
  end

  test "a separate audio rendition is read along with every video variant" do
    serve(
      """
      #EXTM3U
      #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",DEFAULT=YES,URI="audio/index.m3u8"
      #EXT-X-STREAM-INF:BANDWIDTH=100,AUDIO="aud"
      low/index.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=200,AUDIO="aud"
      high/index.m3u8
      """,
      %{
        "audio/index.m3u8" => @media_ts,
        "audio/seg0.ts" => "audio.ts",
        "low/index.m3u8" => @media_ts,
        "low/seg0.ts" => "video.ts",
        "high/index.m3u8" => @media_ts,
        "high/seg0.ts" => "video.ts"
      }
    )

    assert {:ok, [%{tracks: [@video, @audio]}, %{tracks: [@video, @audio]}]} =
             Description.variants(@base)
  end

  test "an unreadable cmaf init section leaves the tracks unknown" do
    serve(@media_cmaf, %{"init.mp4" => "#EXTM3U"})

    assert {:ok, [%{container: :cmaf, tracks: :unknown}]} = Description.variants(@base)
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
