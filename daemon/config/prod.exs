import Config

# burrito pipes stdout through its launcher and that pipe tends to break;
# stderr is left alone
config :logger, :default_handler, config: [type: :standard_error]
