defmodule StreamDoctor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.fetch_env!(:stream_doctor, :port)

    children =
      [
        StreamDoctor.Server,
        {Bandit, plug: StreamDoctor.Api, port: port}
      ] ++ StreamDoctor.StdinWatcher.child_specs()

    Supervisor.start_link(children, strategy: :one_for_one, name: StreamDoctor.Supervisor)
  end
end
