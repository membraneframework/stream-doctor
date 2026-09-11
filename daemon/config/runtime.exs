import Config

if port = System.get_env("PORT") do
  config :stream_doctor, port: String.to_integer(port)
end
