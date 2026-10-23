defmodule StreamDoctor.HLS.Description do
  @moduledoc """
  Reads the metadata an HLS stream declares about itself in its playlists.
  """

  alias StreamDoctor.HLS.Codecs

  @receive_timeout 5_000
  @undeclared %{
    bandwidth: nil,
    average_bandwidth: nil,
    resolution: nil,
    frame_rate: nil,
    name: nil,
    codecs: nil,
    tracks: :unknown
  }

  @type variant :: %{
          id: non_neg_integer(),
          uri: String.t() | nil,
          bandwidth: non_neg_integer() | nil,
          average_bandwidth: non_neg_integer() | nil,
          resolution: %{width: pos_integer(), height: pos_integer()} | nil,
          frame_rate: float() | nil,
          name: String.t() | nil,
          codecs: String.t() | nil,
          tracks: [Codecs.track()] | :unknown,
          container: :cmaf | :mpeg_ts | nil
        }

  @spec variants(String.t()) :: {:ok, [variant()]} | {:error, String.t()}
  def variants(url) do
    with {:ok, playlist} <- fetch(url) do
      parse_variants(playlist, url)
    end
  end

  defp parse_variants(playlist, url) do
    with {:ok, %{items: items}} <- ExM3U8.deserialize_multivariant_playlist(playlist, []) do
      items
      |> Enum.filter(&match?(%ExM3U8.Tags.Stream{}, &1))
      |> Enum.with_index(&variant(&1, &2, url))
      |> case do
        [] -> {:ok, [sole_variant(playlist, url)]}
        variants -> {:ok, variants}
      end
    end
  end

  defp sole_variant(playlist, url) do
    Map.merge(@undeclared, %{id: 0, uri: url, container: container_of(playlist)})
  end

  defp variant(stream, index, base) do
    url = resolve(base, stream.uri)

    %{
      id: index,
      uri: url,
      bandwidth: stream.bandwidth,
      average_bandwidth: stream.average_bandwidth,
      resolution: resolution(stream.resolution),
      frame_rate: stream.frame_rate,
      name: stream.name,
      codecs: stream.codecs,
      tracks: Codecs.parse(stream.codecs),
      container: container(url)
    }
  end

  defp container(nil), do: nil

  defp container(url) do
    case fetch(url) do
      {:ok, playlist} -> container_of(playlist)
      {:error, _reason} -> nil
    end
  end

  defp container_of(playlist) do
    case ExM3U8.deserialize_media_playlist(playlist, []) do
      {:ok, %{timeline: timeline}} -> segment_format(timeline)
      {:error, _reason} -> nil
    end
  end

  defp segment_format(timeline) do
    if Enum.any?(timeline, &match?(%ExM3U8.Tags.MediaInit{}, &1)), do: :cmaf, else: :mpeg_ts
  end

  defp resolution(nil), do: nil
  defp resolution({width, height}), do: %{width: width, height: height}

  defp resolve(_base, nil), do: nil
  defp resolve(base, uri), do: base |> URI.merge(uri) |> URI.to_string()

  defp fetch(url) do
    case Req.get(url, retry: false, receive_timeout: @receive_timeout) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, "#{url}: HTTP #{status}"}
      {:error, error} -> {:error, "#{url}: #{Exception.message(error)}"}
    end
  end
end
