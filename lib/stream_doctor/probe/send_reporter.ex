defmodule StreamDoctor.Probe.SendReporter do
  @moduledoc """
  Sits right before the RTMP sink and sends `{:frame_sent, t}` to every
  process that called `subscribe/0`. Just for "is it live yet".
  """

  use Membrane.Filter

  @registry StreamDoctor.Registry
  @key :frame_sent

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any)

  @spec subscribe() :: :ok
  def subscribe() do
    {:ok, _owner} = Registry.register(@registry, @key, nil)
    :ok
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    t = System.monotonic_time(:millisecond)

    Registry.dispatch(@registry, @key, fn entries ->
      for {pid, _value} <- entries, do: send(pid, {:frame_sent, t})
    end)

    {[buffer: {:output, buffer}], state}
  end
end
