defmodule StreamDoctor.HLS.Description do
  @moduledoc """
  Reads the metadata an HLS stream declares about itself in its playlists.
  """

  alias ExM3U8.Tags
  alias StreamDoctor.HLS.{Codecs, Media}

  @receive_timeout 5_000
  @undeclared %{
    bandwidth: nil,
    average_bandwidth: nil,
    resolution: nil,
    frame_rate: nil,
    name: nil,
    codecs: nil
  }
  @no_media %{container: nil, sample: nil}

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
      |> Enum.filter(&match?(%Tags.Stream{}, &1))
      |> Enum.with_index(&variant(&1, &2, url, items))
      |> case do
        [] -> {:ok, [sole_variant(playlist, url)]}
        variants -> {:ok, variants}
      end
    end
  end

  defp sole_variant(playlist, url) do
    media = media_of(playlist, url)

    Map.merge(@undeclared, %{
      id: 0,
      uri: url,
      tracks: read_tracks([media]),
      container: media.container
    })
  end

  defp variant(stream, index, base, items) do
    url = resolve(base, stream.uri)
    media = media(url)

    %{
      id: index,
      uri: url,
      bandwidth: stream.bandwidth,
      average_bandwidth: stream.average_bandwidth,
      resolution: resolution(stream.resolution),
      frame_rate: stream.frame_rate,
      name: stream.name,
      codecs: stream.codecs,
      tracks: tracks(stream, media, base, items),
      container: media.container
    }
  end

  defp tracks(%{codecs: nil} = stream, media, base, items) do
    read_tracks([media, audio_rendition(stream, base, items)])
  end

  defp tracks(stream, _media, _base, _items) do
    Codecs.parse(stream.codecs)
  end

  defp audio_rendition(%{audio: group}, base, items) do
    rendition =
      Enum.find(items, &match?(%Tags.Media{type: :audio, group_id: ^group, uri: "" <> _}, &1))

    media(rendition && resolve(base, rendition.uri))
  end

  defp read_tracks(medias) do
    case Enum.flat_map(medias, &media_tracks/1) do
      [] -> :unknown
      tracks -> tracks
    end
  end

  defp media_tracks(%{sample: nil}) do
    []
  end

  defp media_tracks(%{container: container, sample: url}) do
    case fetch(url) do
      {:ok, binary} -> Media.tracks(container, binary)
      {:error, _reason} -> []
    end
  end

  defp media(nil) do
    @no_media
  end

  defp media(url) do
    case fetch(url) do
      {:ok, playlist} -> media_of(playlist, url)
      {:error, _reason} -> @no_media
    end
  end

  defp media_of(playlist, url) do
    case ExM3U8.deserialize_media_playlist(playlist, []) do
      {:ok, %{timeline: timeline}} ->
        init = last(timeline, Tags.MediaInit)
        sample = init || last(timeline, Tags.Segment)

        %{
          container: if(init, do: :cmaf, else: :mpeg_ts),
          sample: sample && resolve(url, sample.uri)
        }

      {:error, _reason} ->
        @no_media
    end
  end

  # The newest entry is the one a live playlist is least likely to have expired already.
  defp last(timeline, tag) do
    timeline |> Enum.reverse() |> Enum.find(&is_struct(&1, tag))
  end

  defp resolution(nil) do
    nil
  end

  defp resolution({width, height}) do
    %{width: width, height: height}
  end

  defp resolve(_base, nil) do
    nil
  end

  defp resolve(base, uri) do
    base |> URI.merge(uri) |> URI.to_string()
  end

  defp fetch(url) do
    case Req.get(url, retry: false, receive_timeout: @receive_timeout) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, "#{url}: HTTP #{status}"}
      {:error, error} -> {:error, "#{url}: #{Exception.message(error)}"}
    end
  end
end
