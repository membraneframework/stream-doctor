defmodule StreamDoctor.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # pub/sub for the streamer's send events - every metric collector
      # subscribes to them (see StreamDoctor.Metric.Collector)
      {Registry, keys: :duplicate, name: StreamDoctor.Registry}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: StreamDoctor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
