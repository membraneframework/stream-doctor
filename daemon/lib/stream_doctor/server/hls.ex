defmodule StreamDoctor.Server.HLS do
  @moduledoc false

  # The HLS source crashes on a missing playlist, so the viewer waits here until one is served.

  alias StreamDoctor.HLS.Codecs
  alias StreamDoctor.Metric

  @poll_interval 200
  @receive_timeout 5_000

  @doc """
  Polls `url` until a media playlist lists a segment, descending into a master's first video
  variant. Returns when that segment was first seen. Raises on timeout.
  """
  @spec await_first_segment(String.t(), non_neg_integer()) :: integer()
  def await_first_segment(url, timeout) do
    poll(url, %{entry: url, deadline: Metric.now_ms() + timeout})
  end

  defp poll(url, config) do
    at = Metric.now_ms()

    case classify(url) do
      :segments -> at
      {:variant, ^url} -> retry(config, "variant has no segments yet")
      {:variant, variant_url} -> descend(variant_url, config, "variant has no segments yet")
      :no_segments -> retry(config, "#{url}: playlist has no segments yet")
      {:error, reason} -> retry(config, reason)
    end
  end

  defp descend(url, config, reason) do
    deadline!(url, config, reason)
    poll(url, config)
  end

  defp retry(config, reason) do
    deadline!(config.entry, config, reason)
    Process.sleep(@poll_interval)
    poll(config.entry, config)
  end

  defp deadline!(url, config, reason) do
    if Metric.now_ms() > config.deadline do
      raise "HLS playlist not available at #{url} within timeout (last error: #{reason})"
    end
  end

  defp classify(url) do
    with {:ok, body} <- fetch(url) do
      cond do
        body =~ "#EXTINF" -> :segments
        body =~ "#EXT-X-STREAM-INF" -> variant(body, url)
        true -> :no_segments
      end
    end
  end

  defp variant(body, base) do
    with {:ok, %{items: items}} <- ExM3U8.deserialize_multivariant_playlist(body, []),
         %ExM3U8.Tags.Stream{uri: uri} <- pick(items) do
      {:variant, resolve(base, uri)}
    else
      _unusable -> :no_segments
    end
  end

  defp pick(items) do
    streams = Enum.filter(items, &match?(%ExM3U8.Tags.Stream{uri: uri} when is_binary(uri), &1))
    Enum.find(streams, &video?/1) || List.first(streams)
  end

  defp video?(%ExM3U8.Tags.Stream{codecs: codecs}) do
    case Codecs.parse(codecs) do
      :unknown -> false
      tracks -> Enum.any?(tracks, &(&1.type == :video))
    end
  end

  defp fetch(url) do
    case Req.get(url, retry: false, receive_timeout: @receive_timeout) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        # RFC 8216 section 4 allows either line terminator, ExM3U8 raises on CR.
        {:ok, String.replace(body, "\r\n", "\n")}

      {:ok, %Req.Response{status: status}} ->
        {:error, "#{url}: HTTP #{status}"}

      {:error, error} ->
        {:error, "#{url}: #{Exception.message(error)}"}
    end
  end

  # A variant URI without a query inherits the master's, which carries CDN tokens - same origin only.
  defp resolve(_base, nil), do: nil

  defp resolve(base, uri) do
    base = URI.parse(base)
    merged = URI.merge(base, uri)

    if origin(merged) == origin(base),
      do: URI.to_string(%{merged | query: merged.query || base.query}),
      else: URI.to_string(merged)
  end

  defp origin(uri), do: {uri.scheme, uri.host, uri.port}
end
