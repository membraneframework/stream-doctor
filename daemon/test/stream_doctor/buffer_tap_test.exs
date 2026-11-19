defmodule StreamDoctor.BufferTapTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.{Buffer, Testing}

  test "buffers pass through unchanged and are reported with their index" do
    test_pid = self()
    payloads = ["a", "b", "c"]

    spec =
      child(:source, %Testing.Source{output: payloads})
      |> child(:tap, %StreamDoctor.BufferTap{
        on_buffer: fn buffer, index -> send(test_pid, {:tapped, buffer.payload, index}) end
      })
      |> child(:sink, Testing.Sink)

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)

    for {payload, index} <- Enum.with_index(payloads) do
      assert_receive {:tapped, ^payload, ^index}
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: ^payload})
    end

    assert_end_of_stream(pipeline, :sink)
    Testing.Pipeline.terminate(pipeline)
  end
end
