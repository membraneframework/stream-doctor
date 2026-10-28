defmodule StreamDoctor.Probe.ToneTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.Probe.Audio.Tone

  @sample_rate 44_100

  defp to_floats(s16_binary) do
    for <<sample::16-signed-little <- s16_binary>>, into: <<>> do
      <<sample * 1.0::float-64-little>>
    end
  end

  test "symbol round-trip" do
    for symbol_number <- [0, 1, 42, 127, 130] do
      window = symbol_number |> Tone.symbol_samples(@sample_rate) |> to_floats()

      assert {:ok, rem(symbol_number, Tone.max_symbol())} ==
               Tone.decode_window(window, @sample_rate)
    end
  end

  test "native encode round-trips through decode_window" do
    tone = Tone.new(@sample_rate)
    silence = :binary.copy(<<0::16>>, Tone.symbol_length(@sample_rate))

    for symbol_number <- [0, 1, 42, 127, 130] do
      window = silence |> Tone.encode(tone, symbol_number) |> to_floats()

      assert {:ok, rem(symbol_number, Tone.max_symbol())} ==
               Tone.decode_window(window, @sample_rate)
    end
  end

  test "find_alignment recovers the symbol boundary" do
    symbol_length = Tone.symbol_length(@sample_rate)
    offset = div(symbol_length, 3)
    silence = :binary.copy(<<0::16>>, offset)

    symbols =
      Enum.map(
        100..(100 + Tone.alignment_buffer_symbols()),
        &Tone.symbol_samples(&1, @sample_rate)
      )

    buffer = to_floats(IO.iodata_to_binary([silence | symbols]))

    assert {:ok, found} = Tone.find_alignment(buffer, @sample_rate)
    assert abs(found - offset) <= div(symbol_length, 16)

    assert :error ==
             Tone.find_alignment(
               to_floats(:binary.copy(<<0::16>>, div(byte_size(buffer), 8))),
               @sample_rate
             )
  end

  test "silence reports missing marker" do
    n = Tone.symbol_length(@sample_rate)
    silence = :binary.copy(<<0.0::float-64-little>>, n)
    assert {:error, :markers_not_found} == Tone.decode_window(silence, @sample_rate)
  end

  test "decode survives spectral tilt attenuating high frequencies" do
    # Symbol 42 = 0b0101010 -> data tones at 1500, 2500, 3500 Hz; odd bit sum
    # -> parity tone at 4500 Hz; plus the 500 Hz reference. Amplitudes fall
    # with frequency (~ -9.5 dB power at 4.5 kHz), as after lowpass filtering.
    n = Tone.symbol_length(@sample_rate)

    window =
      for i <- 0..(n - 1), into: <<>> do
        value =
          [500, 1500, 2500, 3500, 4500]
          |> Enum.map(fn freq ->
            amplitude = 3000 * :math.sqrt(500 / freq)
            amplitude * :math.sin(2 * :math.pi() * freq * i / @sample_rate)
          end)
          |> Enum.sum()

        <<value::float-64-little>>
      end

    assert {:ok, 42} == Tone.decode_window(window, @sample_rate)
  end

  test "decode survives small misalignment and noise" do
    shift = div(Tone.symbol_length(@sample_rate), 32)

    stream =
      [41, 42, 43]
      |> Enum.map(&Tone.symbol_samples(&1, @sample_rate))
      |> IO.iodata_to_binary()
      |> to_floats()

    symbol_bytes = Tone.symbol_length(@sample_rate) * 8

    noisy_window =
      stream
      |> binary_part(symbol_bytes + shift * 8, symbol_bytes)
      |> then(fn window ->
        for <<sample::float-64-little <- window>>, into: <<>> do
          <<sample + 200.0 * :math.sin(sample)::float-64-little>>
        end
      end)

    assert {:ok, 42} == Tone.decode_window(noisy_window, @sample_rate)
  end
end
