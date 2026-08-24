defmodule StreamDoctor.Api do
  @moduledoc """
  HTTP API for latency measurement, served by `mix stream_doctor.server`.

  Endpoints (all JSON):

    * `POST /streamer` - body `{"input": "test.mp4", "rtmp_url": "rtmps://..."}`;
      starts the streamer pipeline (one at a time),
    * `GET /streamer` / `DELETE /streamer` - status / stop,
    * `POST /viewers` - body `{"hls_url": "https://....m3u8"}` with optional
      `"metrics": ["latency", "ttff", "av_drift"]` (default: all); waits for
      the playlist in the background and starts a viewer pipeline; returns its
      `id`,
    * `GET /viewers/:id` - viewer status; measurements are under `metrics`,
      keyed by metric name (see `StreamDoctor.Metric`), e.g.
      `metrics.latency.latency_ms`, `metrics.ttff.time_to_first_frame_ms`,
      `metrics.av_drift.drift_ms`,
    * `DELETE /viewers/:id` - stop the viewer,
    * `POST /players/:id/frames` - body: a PNG screenshot of the played video
      (content-type `image/png`); decodes the frame number from the bar and
      returns `{"decoded": true, "frame": n, "latency_ms": ms}` (latency_ms is
      null when the frame's send time is unknown) or
      `{"decoded": false, "reason": "..."}`. The player entry is created on
      first use,
    * `GET /players/:id` - player status; `metrics.latency.latency_ms` is the
      latency of the latest decoded screenshot,
    * `GET /status` - streamer + all viewers + all players.
  """

  use Plug.Router

  alias StreamDoctor.Server

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    # screenshots are read manually with read_body/2 in their route
    pass: ["image/png", "application/octet-stream"],
    json_decoder: JSON
  )

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
      %{"hls_url" => hls_url} = params ->
        case Server.start_viewer(hls_url, params["metrics"]) do
          {:ok, viewer} ->
            send_json(conn, 201, viewer)

          {:error, {:unknown_metric, name}} ->
            known = StreamDoctor.Metric.names() |> Enum.join(", ")
            send_json(conn, 400, %{error: "unknown metric #{inspect(name)} (known: #{known})"})
        end

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

  post "/players/:id/frames" do
    # timestamped before decoding, so the ffmpeg conversion doesn't count
    # towards the measured latency
    t = System.monotonic_time(:millisecond)

    case Plug.Conn.read_body(conn, length: 20_000_000) do
      {:ok, png, conn} ->
        result = StreamDoctor.Probe.ImageMarkerDecoder.decode_frame_number(png)
        send_json(conn, 200, Server.record_player_frame(id, result, t))

      {_more_or_error, _partial, conn} ->
        send_json(conn, 413, %{error: "screenshot too large"})
    end
  end

  get "/players/:id" do
    case Server.player(id) do
      {:ok, player} -> send_json(conn, 200, player)
      {:error, :not_found} -> send_json(conn, 404, %{error: "no player #{id}"})
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
