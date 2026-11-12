defmodule StreamDoctor.HLS.Media do
  @moduledoc """
  Reads the tracks out of the media itself, for playlists that declare no `CODECS`.
  """

  alias Membrane.{AAC, H264}
  alias Membrane.MP4.Demuxer.CMAF
  alias MPEG.TS.Demuxer
  alias StreamDoctor.HLS.Codecs

  # The spec of `MPEG.TS.Demuxer.demux/2` rejects the struct its own `new/0` returns.
  @dialyzer {:nowarn_function, codecs: 2, ts_codec: 2}

  @sps ~r/\x00\x00\x01[\x27\x47\x67](.{3})/s

  @spec tracks(:cmaf | :mpeg_ts, binary()) :: [Codecs.track()]
  def tracks(container, binary) do
    container
    |> codecs(binary)
    |> Enum.sort()
    |> Enum.map_join(",", fn {_id, codec} -> codec end)
    |> Codecs.parse()
  end

  defp codecs(:cmaf, init) do
    {:ok, tracks} = CMAF.Engine.new() |> CMAF.Engine.feed!(init) |> CMAF.Engine.get_tracks_info()
    Enum.map(tracks, fn {id, format} -> {id, cmaf_codec(format)} end)
  end

  defp codecs(:mpeg_ts, segment) do
    demuxer = Demuxer.new()
    {packets, demuxer} = Demuxer.demux(demuxer, segment)
    {flushed, demuxer} = Demuxer.flush(demuxer)
    packets = packets ++ flushed

    for {pid, %{stream_type: type}} <- demuxer.streams, type != :METADATA_IN_PES do
      payloads = for %{pid: ^pid, payload: %{data: data}} <- packets, do: data
      {pid, ts_codec(type, payloads)}
    end
  end

  defp cmaf_codec(%H264{stream_structure: {_avc, <<1, params::binary-size(3), _rest::binary>>}}) do
    avc1(params)
  end

  defp cmaf_codec(%AAC{config: {:esds, esds}}) do
    mp4a(AAC.Parser.Esds.parse_esds(esds).profile)
  end

  defp cmaf_codec(%format{}) do
    inspect(format)
  end

  defp ts_codec(:H264_AVC, payloads) do
    # The three bytes after the SPS header are the ones `avc1.PPCCLL` spells out.
    payloads
    |> Enum.find_value(<<>>, fn data -> Regex.run(@sps, data, capture: :all_but_first) end)
    |> IO.iodata_to_binary()
    |> avc1()
  end

  defp ts_codec(:AAC_ADTS, [<<0xFFF::12, _flags::4, profile::2, _rest::bits>> | _payloads]) do
    "mp4a.40.#{profile + 1}"
  end

  defp ts_codec(type, _payloads) do
    type |> inspect() |> String.trim_leading(":")
  end

  defp avc1(params) do
    "avc1." <> Base.encode16(params)
  end

  defp mp4a(profile) do
    "mp4a.40.#{AAC.profile_to_aot_id(profile)}"
  end
end
