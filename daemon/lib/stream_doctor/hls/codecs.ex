defmodule StreamDoctor.HLS.Codecs do
  @moduledoc """
  Reads the tracks of an HLS variant, from its `CODECS` attribute or from the media itself.
  """

  alias Membrane.{AAC, H264}
  alias Membrane.MP4.Demuxer.CMAF
  alias MPEG.TS.Demuxer

  # The spec of `MPEG.TS.Demuxer.demux/2` rejects the struct its own `new/0` returns.
  @dialyzer {:nowarn_function, tracks_by_id: 2, ts_track: 2}

  # The three bytes after the SPS header are profile_idc, the constraint flags and level_idc.
  @sps ~r/\x00\x00\x01[\x27\x47\x67](.{3})/s

  @type track ::
          %{type: :video, codec: :h264, profile: atom() | nil, level: String.t() | nil}
          | %{type: :audio, codec: :aac, profile: Membrane.AAC.profile(), level: nil}
          | %{type: :unknown, raw: String.t()}

  @aac_object_types [1, 2, 3, 4, 5, 29]

  # RFC 6381 avc1.PPCCLL: profile_idc, constraint_set flags, level_idc
  @h264_profiles [
    {44, [], :high_cavlc_4_4_4_intra},
    {66, [1], :constrained_baseline},
    {66, [], :baseline},
    {77, [], :main},
    {88, [], :extended},
    {100, [4, 5], :constrained_high},
    {100, [4], :progressive_high},
    {100, [], :high},
    {110, [3], :high_10_intra},
    {110, [], :high_10},
    {122, [3], :high_4_2_2_intra},
    {122, [], :high_4_2_2},
    {244, [3], :high_4_4_4_intra},
    {244, [], :high_4_4_4_predictive}
  ]

  @spec parse(String.t() | nil) :: [track()] | :unknown
  def parse(nil), do: :unknown

  def parse(codecs) do
    codecs
    |> String.split(",", trim: true)
    |> Enum.map(&track(String.trim(&1)))
  end

  @spec from_media(:cmaf | :mpeg_ts, binary()) :: [track()] | :unknown
  def from_media(container, binary) do
    case tracks_by_id(container, binary) do
      [] -> :unknown
      tracks -> tracks |> Enum.sort() |> Enum.map(fn {_id, track} -> track end)
    end
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
    h264(params)
  end

  defp cmaf_track(%AAC{config: {:esds, esds}}) do
    aac(AAC.Parser.Esds.parse_esds(esds).profile)
  end

  defp cmaf_track(%format{}) do
    unknown(inspect(format))
  end

  defp ts_track(:H264_AVC, payloads) do
    case Enum.find_value(payloads, &Regex.run(@sps, &1, capture: :all_but_first)) do
      [params] -> h264(params)
      nil -> h264(nil)
    end
  end

  defp ts_track(:AAC_ADTS, [<<0xFFF::12, _flags::4, profile::2, _rest::bits>> | _payloads]) do
    aac(AAC.aot_id_to_profile(profile + 1))
  end

  defp ts_track(type, _payloads) do
    unknown(type |> inspect() |> String.trim_leading(":"))
  end

  defp track("avc1." <> params) do
    case Base.decode16(params, case: :mixed) do
      {:ok, params} -> h264(params)
      :error -> h264(nil)
    end
  end

  defp track("mp4a.40." <> aot = raw) do
    case Integer.parse(aot) do
      {id, ""} when id in @aac_object_types ->
        aac(Membrane.AAC.aot_id_to_profile(id))

      _ ->
        unknown(raw)
    end
  end

  defp track(raw), do: unknown(raw)

  defp h264(<<profile_idc, constraints, level_idc>>) do
    %{
      type: :video,
      codec: :h264,
      profile: h264_profile(profile_idc, constraints),
      level: h264_level(level_idc, profile_idc, constraints)
    }
  end

  defp h264(_params) do
    %{type: :video, codec: :h264, profile: nil, level: nil}
  end

  defp aac(profile), do: %{type: :audio, codec: :aac, profile: profile, level: nil}

  defp unknown(raw), do: %{type: :unknown, raw: raw}

  defp h264_profile(profile_idc, constraints) do
    Enum.find_value(@h264_profiles, fn {idc, sets, profile} ->
      if idc == profile_idc and Enum.all?(sets, &constraint_set?(constraints, &1)), do: profile
    end)
  end

  defp constraint_set?(constraints, index) do
    <<_before::size(^index), bit::1, _rest::bits>> = <<constraints>>
    bit == 1
  end

  # H.264 Annex A: level_idc 11 only means level 1b for profile_idc 66, 77 and 88
  defp h264_level(11, profile_idc, constraints) when profile_idc in [66, 77, 88] do
    if constraint_set?(constraints, 3), do: "1b", else: "1.1"
  end

  defp h264_level(9, _profile_idc, _constraints), do: "1b"

  defp h264_level(level_idc, _profile_idc, _constraints),
    do: "#{div(level_idc, 10)}.#{rem(level_idc, 10)}"
end
