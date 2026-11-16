defmodule StreamDoctor.HLS.Media do
  @moduledoc """
  Reads the tracks out of the media itself, for playlists that declare no `CODECS`.
  """

  alias Membrane.{AAC, H264}
  alias Membrane.MP4.Demuxer.CMAF
  alias MPEG.TS.Demuxer
  alias StreamDoctor.HLS.Codecs

  # The spec of `MPEG.TS.Demuxer.demux/2` rejects the struct its own `new/0` returns.
  @dialyzer {:nowarn_function, tracks_by_id: 2, ts_track: 2}

  # The three bytes after the SPS header are profile_idc, the constraint flags and level_idc.
  @sps ~r/\x00\x00\x01[\x27\x47\x67](.{3})/s

  @spec tracks(:cmaf | :mpeg_ts, binary()) :: [Codecs.track()]
  def tracks(container, binary) do
    container
    |> tracks_by_id(binary)
    |> Enum.sort()
    |> Enum.map(fn {_id, track} -> track end)
  end

  defp tracks_by_id(:cmaf, init) do
    case CMAF.Engine.new() |> CMAF.Engine.feed!(init) |> CMAF.Engine.get_tracks_info() do
      {:ok, tracks} -> Enum.map(tracks, fn {id, format} -> {id, cmaf_track(format)} end)
      {:error, :not_available_yet} -> []
    end
  end

  defp tracks_by_id(:mpeg_ts, segment) do
    demuxer = Demuxer.new()
    {packets, demuxer} = Demuxer.demux(demuxer, segment)
    {flushed, demuxer} = Demuxer.flush(demuxer)
    packets = packets ++ flushed

    for {pid, %{stream_type: type}} <- demuxer.streams, type != :METADATA_IN_PES do
      payloads = for %{pid: ^pid, payload: %{data: data}} <- packets, do: data
      {pid, ts_track(type, payloads)}
    end
  end

  defp cmaf_track(%H264{stream_structure: {_avc, <<1, params::binary-size(3), _rest::binary>>}}) do
    Codecs.h264(params)
  end

  defp cmaf_track(%AAC{config: {:esds, esds}}) do
    Codecs.aac(AAC.Parser.Esds.parse_esds(esds).profile)
  end

  defp cmaf_track(%format{}) do
    Codecs.unknown(inspect(format))
  end

  defp ts_track(:H264_AVC, payloads) do
    payloads
    |> Enum.find_value(<<>>, fn data -> Regex.run(@sps, data, capture: :all_but_first) end)
    |> IO.iodata_to_binary()
    |> Codecs.h264()
  end

  defp ts_track(:AAC_ADTS, [<<0xFFF::12, _flags::4, profile::2, _rest::bits>> | _payloads]) do
    Codecs.aac(AAC.aot_id_to_profile(profile + 1))
  end

  defp ts_track(type, _payloads) do
    Codecs.unknown(type |> inspect() |> String.trim_leading(":"))
  end
end
