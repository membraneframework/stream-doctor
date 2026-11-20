defmodule StreamDoctor.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Running stream-doctor v#{Application.spec(:stream_doctor, :vsn)}")
    port = Application.fetch_env!(:stream_doctor, :port)

    # A temporary child stopped by rest_for_one is not started again, so the watcher goes first.
    children =
      StreamDoctor.StdinWatcher.child_specs() ++
        [
          StreamDoctor.Server,
          {DynamicSupervisor, name: StreamDoctor.WorkerSupervisor},
          {Bandit, plug: StreamDoctor.Api, port: port}
        ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: StreamDoctor.Supervisor)
  end
end
