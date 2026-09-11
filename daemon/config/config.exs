import Config

config :stream_doctor, port: 4040
config :logger, level: :info

import_config "#{config_env()}.exs"
