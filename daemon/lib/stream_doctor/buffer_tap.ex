defmodule StreamDoctor.BufferTap do
  @moduledoc """
  Passes buffers through unchanged, calling `on_buffer` with each buffer and its index in arrival
  order, counted from zero.
  """

  use Membrane.Filter

  def_input_pad :input, accepted_format: _any
  def_output_pad :output, accepted_format: _any

  def_options on_buffer: [
                spec: (Membrane.Buffer.t(), non_neg_integer() -> any()),
                description: "Called with each buffer and its index"
              ]

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{on_buffer: opts.on_buffer, index: 0}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    state.on_buffer.(buffer, state.index)
    {[buffer: {:output, buffer}], %{state | index: state.index + 1}}
  end
end
