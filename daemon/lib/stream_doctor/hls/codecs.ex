defmodule StreamDoctor.HLS.Codecs do
  @moduledoc """
  Reads the tracks an HLS variant declares in its `CODECS` attribute.
  """

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

  @spec parse(String.t() | nil) :: [map()]
  def parse(nil), do: []

  def parse(codecs) do
    codecs
    |> String.split(",", trim: true)
    |> Enum.map(&track(String.trim(&1)))
  end

  defp track("avc1." <> params = raw) do
    case Base.decode16(params, case: :mixed) do
      {:ok, <<profile_idc, constraints, level_idc>>} ->
        %{
          type: :video,
          codec: :h264,
          profile: h264_profile(profile_idc, constraints),
          level: h264_level(level_idc, profile_idc, constraints)
        }

      _ ->
        unknown(raw)
    end
  end

  defp track("mp4a.40." <> aot = raw) do
    case Integer.parse(aot) do
      {id, ""} when id in @aac_object_types ->
        %{type: :audio, codec: :aac, profile: Membrane.AAC.aot_id_to_profile(id), level: nil}

      _ ->
        unknown(raw)
    end
  end

  defp track(raw), do: unknown(raw)

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
