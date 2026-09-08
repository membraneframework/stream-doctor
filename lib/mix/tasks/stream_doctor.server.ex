defmodule Mix.Tasks.StreamDoctor.Server do
  @shortdoc "Runs the HTTP server for spawning a streamer/viewers and reading A/V drift"

  @moduledoc """
      mix stream_doctor.server [--port 4040]

  Endpoints in `StreamDoctor.Api`. Driven by `stream_doctor.mjs`.
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

    IO.puts("stream_doctor server listening on http://localhost:#{port}")
    Process.sleep(:infinity)
  end
end
