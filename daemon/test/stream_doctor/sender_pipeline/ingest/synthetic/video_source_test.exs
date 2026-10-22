defmodule StreamDoctor.SenderPipeline.Ingest.Synthetic.VideoSourceTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.RawVideo
  alias Membrane.Testing
  alias StreamDoctor.Probe.Video.Bar
  alias StreamDoctor.SenderPipeline.Ingest.Synthetic.VideoSource

  @width 640
  @height 360

  defp start(opts) do
    spec =
      child(:source, struct!(VideoSource, opts))
      |> child(:marker, StreamDoctor.Probe.Video.MarkerEncoder)
      |> child(:sink, Testing.Sink)

    pid = Testing.Pipeline.start_link_supervised!(spec: spec)
    on_exit(fn -> Testing.Pipeline.terminate(pid) end)
    pid
  end

  defp source_opts(overrides \\ []) do
    Keyword.merge([width: @width, height: @height, framerate: {30, 1}], overrides)
  end

  test "the frame number drawn by the marker survives the generated frames" do
    pid = start(source_opts())
    geometry = Bar.geometry(@width, @height)

    for n <- 0..39 do
      assert_sink_buffer(pid, :sink, buffer)
      assert {:ok, ^n} = Bar.decode(buffer.payload, geometry)
    end
  end

  test "the frame number stays correct at a fractional frame rate" do
    pid = start(source_opts(framerate: {30_000, 1001}))
    geometry = Bar.geometry(@width, @height)

    for n <- 0..39 do
      assert_sink_buffer(pid, :sink, buffer)
      assert {:ok, ^n} = Bar.decode(buffer.payload, geometry)
    end
  end

  test "the stream format declares the configured size and frame rate" do
    pid = start(source_opts(width: 320, height: 240, framerate: {25, 1}))

    assert_sink_stream_format(pid, :sink, %RawVideo{
      width: 320,
      height: 240,
      pixel_format: :I420,
      framerate: {25, 1},
      aligned: true
    })
  end

  test "every payload is exactly one I420 frame" do
    pid = start(source_opts())
    {:ok, expected} = RawVideo.frame_size(:I420, @width, @height)

    for _n <- 0..9 do
      assert_sink_buffer(pid, :sink, buffer)
      assert byte_size(buffer.payload) == expected
    end
  end

  test "timestamps rise by one frame duration and carry it as metadata" do
    pid = start(source_opts(framerate: {25, 1}))
    expected = div(Membrane.Time.second(), 25)

    for n <- 0..9 do
      assert_sink_buffer(pid, :sink, buffer)
      assert buffer.pts == n * expected
      assert buffer.metadata.duration == expected
    end
  end

  test "frames differ from one another so the encoder has motion to work with" do
    pid = start(source_opts())

    payloads =
      for _n <- 0..9 do
        assert_sink_buffer(pid, :sink, buffer)
        buffer.payload
      end

    assert payloads == Enum.uniq(payloads)
  end

  test "the bouncing square fits a frame taller than it is wide" do
    pid = start(source_opts(width: 320, height: 1440))
    geometry = Bar.geometry(320, 1440)

    for n <- 0..9 do
      assert_sink_buffer(pid, :sink, buffer)
      assert {:ok, ^n} = Bar.decode(buffer.payload, geometry)
    end
  end

  test "the smallest resolution the frame-number bar allows still works" do
    pid = start(source_opts(width: 180, height: 120))
    geometry = Bar.geometry(180, 120)

    for n <- 0..9 do
      assert_sink_buffer(pid, :sink, buffer)
      assert {:ok, ^n} = Bar.decode(buffer.payload, geometry)
    end
  end

  test "a duration ends the stream once it is generated" do
    pid = start(source_opts(duration: Membrane.Time.seconds(1)))

    for _n <- 1..30, do: assert_sink_buffer(pid, :sink, %Membrane.Buffer{})

    assert_end_of_stream(pid, :sink)
  end
end
