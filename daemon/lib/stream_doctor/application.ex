defmodule StreamDoctor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.fetch_env!(:stream_doctor, :port)

    children = [
      {Registry, keys: :duplicate, name: StreamDoctor.Registry},
      StreamDoctor.Server,
      {Bandit, plug: StreamDoctor.Api, port: port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: StreamDoctor.Supervisor)
  end
end
