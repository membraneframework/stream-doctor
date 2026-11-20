import Config

if port = System.get_env("PORT") do
  config :stream_doctor, port: String.to_integer(port)
end

if restarts = System.get_env("RECEIVER_RESTARTS") do
  config :stream_doctor, receiver_restarts: String.to_integer(restarts)
end

if delay = System.get_env("RECEIVER_RESTART_DELAY_MS") do
  config :stream_doctor, receiver_restart_delay_ms: String.to_integer(delay)
end
