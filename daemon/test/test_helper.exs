# The default 100 ms is too short for a loaded CI runner.
ExUnit.start(assert_receive_timeout: 2_000)

Req.default_options(plug: {Req.Test, :http})
