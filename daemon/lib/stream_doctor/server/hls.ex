defmodule StreamDoctor.Server.HLS do
  @moduledoc false

  # The HLS source crashes on a missing playlist, so the viewer waits here until one is served.

  @doc "Polls `url` until the playlist lists segments or variants. Raises on timeout."
  @spec await_playlist(String.t(), non_neg_integer()) :: :ok
  def await_playlist(url, timeout) do
    poll(url, now_ms() + timeout)
  end

  defp poll(url, deadline) do
    case fetch(url) do
      :ok ->
        :ok

      {:error, reason} ->
        if now_ms() > deadline do
          raise "HLS playlist not available at #{url} within timeout (last error: #{reason})"
        end

        Process.sleep(1_000)
        poll(url, deadline)
    end
  end

  defp fetch(url) do
    case Req.get(url, retry: false, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        if body =~ "#EXTINF" or body =~ "#EXT-X-STREAM-INF",
          do: :ok,
          else: {:error, "playlist has no segments yet"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  defp now_ms do
    System.monotonic_time(:millisecond)
  end
end
