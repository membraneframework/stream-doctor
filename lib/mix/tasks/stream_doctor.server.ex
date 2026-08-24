defmodule Mix.Tasks.StreamDoctor.Server do
  @shortdoc "Runs the HTTP server for spawning streamer/viewers and reading latency"

  @moduledoc """
  Runs the latency-measurement HTTP server (see `StreamDoctor.Api` for the
  endpoints).

      mix stream_doctor.server [--port 4040]

  Meant to be driven by `latency_client.mjs` / `create_livestream.mjs`, or
  directly:

      curl -X POST localhost:4040/streamer \\
        -H 'content-type: application/json' \\
        -d '{"input": "test.mp4", "rtmp_url": "rtmps://..."}'
      curl -X POST localhost:4040/viewers \\
        -H 'content-type: application/json' \\
        -d '{"hls_url": "https://....m3u8"}'
      curl localhost:4040/viewers/viewer-1
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [port: :integer])
    port = opts[:port] || 4040

    Mix.Task.run("app.start")
    Logger.configure(level: :info)

    {:ok, _server} = StreamDoctor.Server.start_link()
    {:ok, _bandit} = Bandit.start_link(plug: StreamDoctor.Api, port: port)

    IO.puts("stream_doctor latency server listening on http://localhost:#{port}")
    Process.sleep(:infinity)
  end
end
