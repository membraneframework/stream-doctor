import Config

config :stream_doctor, port: 4040, receiver_restarts: 5, receiver_restart_delay_ms: 1_000
config :logger, level: :info

import_config "#{config_env()}.exs"
