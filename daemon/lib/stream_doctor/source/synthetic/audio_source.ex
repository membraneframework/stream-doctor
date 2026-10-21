defmodule StreamDoctor.Source.Synthetic.AudioSource do
  @moduledoc """
  Generates mono s16le silence in AAC-sized chunks.

  `StreamDoctor.Probe.Audio.MarkerEncoder` replaces the payload with its tones, so only the
  timing and the frame counts matter here.
  """

  use Membrane.Source

  alias Membrane.{Buffer, RawAudio}

  def_options sample_rate: [spec: pos_integer()],
              duration: [spec: Membrane.Time.t() | nil, default: nil]

  def_output_pad :output,
    accepted_format: %RawAudio{sample_format: :s16le, channels: 1},
    flow_control: :manual

  @frames_per_buffer 1024

  @impl true
  def handle_init(_ctx, opts) do
    format = %RawAudio{sample_format: :s16le, channels: 1, sample_rate: opts.sample_rate}

    state = %{
      format: format,
      frame_size: RawAudio.frame_size(format),
      frames: 0,
      samples: samples(opts.duration, opts.sample_rate),
      payload: format |> RawAudio.silence() |> :binary.copy(@frames_per_buffer)
    }

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[stream_format: {:output, state.format}], state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, state) do
    if over?(state) do
      {[end_of_stream: :output], state}
    else
      count = chunk_frames(state)
      pts = div(state.frames * Membrane.Time.second(), state.format.sample_rate)
      payload = binary_part(state.payload, 0, count * state.frame_size)
      buffer = %Buffer{payload: payload, pts: pts}

      {[buffer: {:output, buffer}, redemand: :output], %{state | frames: state.frames + count}}
    end
  end

  defp chunk_frames(%{samples: nil}), do: @frames_per_buffer

  defp chunk_frames(%{samples: samples, frames: frames}),
    do: min(@frames_per_buffer, samples - frames)

  defp samples(nil, _sample_rate), do: nil
  defp samples(duration, sample_rate), do: div(duration * sample_rate, Membrane.Time.second())

  defp over?(%{samples: nil}), do: false
  defp over?(%{samples: samples, frames: frames}), do: frames >= samples
end
