defmodule StreamDoctor.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Running stream-doctor v#{Application.spec(:stream_doctor, :vsn)}")
    port = Application.fetch_env!(:stream_doctor, :port)

    # With rest_for_one the order is crucial: the stdin watcher goes first so that it is not stopped
    # when a child after it dies, because as a temporary child it would never be started again.
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
