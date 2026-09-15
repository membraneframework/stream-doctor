defmodule StreamDoctor.SenderPipeline.DurationAdder do
  @moduledoc """
  Puts the time until the next buffer into each buffer's `metadata.duration`.
  """

  use Membrane.Filter

  def_input_pad :input, accepted_format: _any
  def_output_pad :output, accepted_format: _any

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{held: nil, pending: [], last_duration: nil}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %{held: nil} = state) do
    {[], %{state | held: buffer}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    duration = timestamp(buffer) - timestamp(state.held)

    if duration <= 0 do
      raise "Non-increasing timestamps: #{timestamp(state.held)} then #{timestamp(buffer)}"
    end

    {[buffer: {:output, stamp(state.held, duration)}] ++ Enum.reverse(state.pending),
     %{state | held: buffer, pending: [], last_duration: duration}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    forward({:stream_format, {:output, stream_format}}, state)
  end

  @impl true
  def handle_event(:input, event, _ctx, state) do
    forward({:event, {:output, event}}, state)
  end

  @impl true
  def handle_event(:output, event, _ctx, state) do
    {[event: {:input, event}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{held: nil} = state) do
    {[end_of_stream: :output], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    duration = state.last_duration || raise "Cannot infer duration of a single buffer"

    {[buffer: {:output, stamp(state.held, duration)}] ++
       Enum.reverse(state.pending) ++ [end_of_stream: :output], %{state | held: nil, pending: []}}
  end

  defp forward(action, %{held: nil} = state) do
    {[action], state}
  end

  defp forward(action, state) do
    {[], %{state | pending: [action | state.pending]}}
  end

  defp timestamp(buffer) do
    buffer.dts || buffer.pts
  end

  defp stamp(buffer, duration) do
    %{buffer | metadata: Map.put(buffer.metadata, :duration, duration)}
  end
end
