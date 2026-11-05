defmodule StreamDoctor.Server.HLS do
  @moduledoc false

  # The HLS source crashes on a missing playlist, so the viewer waits here until one is served.

  alias StreamDoctor.Metric

  @poll_interval 200

  @doc "Polls `url` until a media playlist lists a segment, descending into a master's first variant. Returns when that segment was first seen. Raises on timeout."
  @spec await_first_segment(String.t(), non_neg_integer()) :: integer()
  def await_first_segment(url, timeout) do
    poll(url, url, Metric.now_ms() + timeout)
  end

  defp poll(url, entry, deadline) do
    at = Metric.now_ms()

    case classify(url) do
      :segments -> at
      {:variant, ^url} -> retry(entry, deadline, "playlist has no segments yet")
      {:variant, variant} -> poll(variant, entry, deadline)
      :no_segments -> retry(entry, deadline, "playlist has no segments yet")
      {:error, reason} -> retry(entry, deadline, reason)
    end
  end

  defp retry(entry, deadline, reason) do
    if Metric.now_ms() > deadline do
      raise "HLS playlist not available at #{entry} within timeout (last error: #{reason})"
    end

    Process.sleep(@poll_interval)
    poll(entry, entry, deadline)
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
         %ExM3U8.Tags.Stream{uri: uri} <- Enum.find(items, &match?(%ExM3U8.Tags.Stream{}, &1)) do
      {:variant, base |> URI.merge(uri) |> URI.to_string()}
    else
      _unusable -> :no_segments
    end
  end

  defp fetch(url) do
    case Req.get(url, retry: false, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end
end
