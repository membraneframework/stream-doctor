defmodule StreamDoctor.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Running stream-doctor v#{Application.spec(:stream_doctor, :vsn)}")
    port = Application.fetch_env!(:stream_doctor, :port)

    children =
      [
        StreamDoctor.Server,
        {Bandit, plug: StreamDoctor.Api, port: port}
      ] ++ StreamDoctor.StdinWatcher.child_specs()

    Supervisor.start_link(children, strategy: :one_for_one, name: StreamDoctor.Supervisor)
  end
end
