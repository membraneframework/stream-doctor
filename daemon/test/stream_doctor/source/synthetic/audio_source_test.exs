defmodule StreamDoctor.Source.Synthetic.AudioSourceTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.RawAudio
  alias Membrane.Testing
  alias StreamDoctor.Probe.Audio.Tone
  alias StreamDoctor.Source.Synthetic.AudioSource

  @sample_rate 48_000
  @frames_per_buffer 1024

  defp start(sample_rate, marked?) do
    source = child(:source, %AudioSource{sample_rate: sample_rate})

    spec =
      if marked?, do: child(source, :marker, StreamDoctor.Probe.Audio.MarkerEncoder), else: source

    pid = Testing.Pipeline.start_link_supervised!(spec: child(spec, :sink, Testing.Sink))
    on_exit(fn -> Testing.Pipeline.terminate(pid) end)
    pid
  end

  defp to_floats(s16_binary) do
    for <<sample::16-signed-little <- s16_binary>>, into: <<>> do
      <<sample * 1.0::float-64-little>>
    end
  end

  defp collect(pid, count) do
    for _n <- 1..count, into: <<>> do
      assert_sink_buffer(pid, :sink, buffer)
      buffer.payload
    end
  end

  test "the stream format is what the marker encoder and the AAC encoder both accept" do
    pid = start(44_100, false)

    assert_sink_stream_format(pid, :sink, %RawAudio{
      sample_format: :s16le,
      channels: 1,
      sample_rate: 44_100
    })
  end

  test "every buffer holds a whole AAC frame worth of samples" do
    pid = start(@sample_rate, false)

    for _n <- 0..9 do
      assert_sink_buffer(pid, :sink, buffer)
      assert byte_size(buffer.payload) == @frames_per_buffer * 2
    end
  end

  test "timestamps follow the cumulative frame count without drifting" do
    pid = start(@sample_rate, false)

    for n <- 0..9 do
      assert_sink_buffer(pid, :sink, buffer)
      assert buffer.pts == div(n * @frames_per_buffer * Membrane.Time.second(), @sample_rate)
    end
  end

  test "symbols stamped by the marker decode back in order" do
    pid = start(@sample_rate, true)
    length = Tone.symbol_length(@sample_rate)
    buffers = ceil(length * 4 / @frames_per_buffer) + 1

    samples = pid |> collect(buffers) |> to_floats()

    decoded =
      for index <- 0..2 do
        window = binary_part(samples, index * length * 8, length * 8)
        Tone.decode_window(window, @sample_rate)
      end

    assert [{:ok, 0}, {:ok, 1}, {:ok, 2}] = decoded
  end

  test "a duration ends the stream once it is generated" do
    spec =
      child(:source, %AudioSource{sample_rate: @sample_rate, duration: Membrane.Time.second()})
      |> child(:sink, Testing.Sink)

    pid = Testing.Pipeline.start_link_supervised!(spec: spec)
    on_exit(fn -> Testing.Pipeline.terminate(pid) end)

    assert_end_of_stream(pid, :sink)
  end
end
