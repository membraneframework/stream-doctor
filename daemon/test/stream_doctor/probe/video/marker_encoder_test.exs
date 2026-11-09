defmodule StreamDoctor.Probe.Video.MarkerEncoderTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.{Buffer, RawVideo, Testing}
  alias StreamDoctor.Probe.Video.{Bar, MarkerEncoder}

  @width 256
  @height 64

  @format %RawVideo{
    width: @width,
    height: @height,
    pixel_format: :I420,
    framerate: {30, 1},
    aligned: true
  }

  defp grey_frame do
    :binary.copy(<<128>>, div(@width * @height * 3, 2))
  end

  defp numbers(timestamps) do
    buffers = Enum.map(timestamps, &%Buffer{payload: grey_frame(), pts: &1})

    spec =
      child(:source, %Testing.Source{output: buffers, stream_format: @format})
      |> child(:encoder, MarkerEncoder)
      |> child(:sink, Testing.Sink)

    pid = Testing.Pipeline.start_link_supervised!(spec: spec)
    on_exit(fn -> Testing.Pipeline.terminate(pid) end)
    bar = Bar.new(@width, @height)

    for _timestamp <- timestamps do
      assert_sink_buffer(pid, :sink, buffer)
      assert {:ok, number} = Bar.decode(bar, buffer.payload)
      number
    end
  end

  test "frames are numbered in arrival order whatever the pts spacing" do
    assert numbers([0, 100, 250, 251, 10_000]) == [0, 1, 2, 3, 4]
  end

  test "a pts that repeats or goes backwards does not disturb the numbering" do
    assert numbers([0, 0, 0, 40, 20, 10]) == [0, 1, 2, 3, 4, 5]
  end

  test "the numbering starts from zero again at Bar.max_frame/0" do
    bar = Bar.new(@width, @height)
    frame = grey_frame()
    {[], state} = MarkerEncoder.handle_init(nil, %{})
    {_actions, state} = MarkerEncoder.handle_stream_format(:input, @format, nil, state)

    {numbers, _state} =
      Enum.map_reduce(0..Bar.max_frame(), state, fn _n, state ->
        {[buffer: {:output, buffer}], state} =
          MarkerEncoder.handle_buffer(:input, %Buffer{payload: frame, pts: 0}, nil, state)

        {Bar.decode(bar, buffer.payload), state}
      end)

    assert Enum.at(numbers, Bar.max_frame() - 1) == {:ok, Bar.max_frame() - 1}
    assert Enum.at(numbers, Bar.max_frame()) == {:ok, 0}
  end
end
