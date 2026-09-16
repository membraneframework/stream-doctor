defmodule StreamDoctor.Api do
  @moduledoc """
  JSON API, listens on `PORT` (default 4040).

    * `POST/GET/DELETE /streamer` - `{"input", "rtmp_url"}`
    * `POST /viewers` - `{"hls_url"}`
    * `GET/DELETE /viewers/:id`
    * `GET /status`
  """

  use Plug.Router

  alias StreamDoctor.Server

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON)
  plug(:dispatch)

  post "/streamer" do
    case conn.body_params do
      %{"input" => input, "rtmp_url" => rtmp_url} ->
        case Server.start_streamer(input, rtmp_url) do
          {:ok, streamer} ->
            send_json(conn, 201, streamer)

          {:error, :already_streaming} ->
            send_json(conn, 409, %{error: "streamer already running - DELETE /streamer first"})
        end

      _params ->
        send_json(conn, 400, %{error: ~s(expected body {"input": "...", "rtmp_url": "..."})})
    end
  end

  get "/streamer" do
    case Server.streamer() do
      {:ok, streamer} -> send_json(conn, 200, streamer)
      {:error, :not_found} -> send_json(conn, 404, %{error: "no streamer started"})
    end
  end

  delete "/streamer" do
    case Server.stop_streamer() do
      {:ok, streamer} -> send_json(conn, 200, streamer)
      {:error, :not_found} -> send_json(conn, 404, %{error: "no streamer started"})
    end
  end

  post "/viewers" do
    case conn.body_params do
      %{"hls_url" => hls_url} ->
        {:ok, viewer} = Server.start_viewer(hls_url)
        send_json(conn, 201, viewer)

      _params ->
        send_json(conn, 400, %{error: ~s(expected body {"hls_url": "..."})})
    end
  end

  get "/viewers/:id" do
    case Server.viewer(id) do
      {:ok, viewer} -> send_json(conn, 200, viewer)
      {:error, :not_found} -> send_json(conn, 404, %{error: "no viewer #{id}"})
    end
  end

  delete "/viewers/:id" do
    case Server.stop_viewer(id) do
      {:ok, viewer} -> send_json(conn, 200, viewer)
      {:error, :not_found} -> send_json(conn, 404, %{error: "no viewer #{id}"})
    end
  end

  get "/status" do
    send_json(conn, 200, Server.status())
  end

  match _ do
    send_json(conn, 404, %{error: "no such endpoint"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
