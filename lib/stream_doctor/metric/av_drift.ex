defmodule StreamDoctor.Metric.AvDrift do
  @moduledoc """
  A/V desync the way a pts-syncing player would see it:

      drift_ms = (audio pts - m * symbol_ms) - (video pts - n * frame_duration)

  Positive = audio content later than video. Arrival times are useless here
  (decoders burst differently), so only timestamps are used. Audio symbols
  wrap every 3.84 s, unwrapped against the video offset, so it's good up to
  ±1.92 s. Reported value is a median.
  """

  @behaviour StreamDoctor.Metric

  alias StreamDoctor.Probe.Audio.MarkerDecoder, as: AudioMarkerDecoder

  @max_samples 50

  @impl true
  def name(), do: :av_drift

  @impl true
  def init(_opts) do
    %{
      video: nil,
      frame_duration: nil,
      video_offset: nil,
      audio: nil,
      samples: []
    }
  end

  @impl true
  def handle_event({:video_frame_received, _n, nil, _t}, state), do: state

  def handle_event({:video_frame_received, n, pts_ms, _t}, state) do
    frame_duration =
      case state.video do
        {last_n, last_pts} when n == last_n + 1 and pts_ms > last_pts -> pts_ms - last_pts
        _other -> state.frame_duration
      end

    video_offset = frame_duration && pts_ms - n * frame_duration

    %{state | video: {n, pts_ms}, frame_duration: frame_duration, video_offset: video_offset}
  end

  def handle_event({:audio_symbol_received, _m, nil, _t}, state), do: state

  def handle_event({:audio_symbol_received, m, pts_ms, _t}, state) do
    case state.video_offset do
      nil ->
        state

      video_offset ->
        m = unwrap(m, pts_ms, state.audio, video_offset)
        drift = pts_ms - m * AudioMarkerDecoder.symbol_ms() - video_offset
        samples = Enum.take([round(drift) | state.samples], @max_samples)
        %{state | audio: m, samples: samples}
    end
  end

  def handle_event(_event, state), do: state

  @impl true
  def report(state) do
    %{
      drift_ms: median(state.samples),
      frame_duration_ms: state.frame_duration && Float.round(state.frame_duration / 1, 2),
      latest_samples: Enum.take(state.samples, 10)
    }
  end

  defp unwrap(m, pts_ms, nil, video_offset) do
    cycle_ms = AudioMarkerDecoder.max_symbol() * AudioMarkerDecoder.symbol_ms()
    target_ms = pts_ms - video_offset
    k = round((target_ms - m * AudioMarkerDecoder.symbol_ms()) / cycle_ms)
    m + k * AudioMarkerDecoder.max_symbol()
  end

  defp unwrap(m, _pts_ms, last, _video_offset) do
    max = AudioMarkerDecoder.max_symbol()
    candidate = div(last, max) * max + m

    cond do
      candidate < last - div(max, 2) -> candidate + max
      candidate > last + div(max, 2) -> candidate - max
      true -> candidate
    end
  end

  defp median([]), do: nil

  defp median(samples) do
    sorted = Enum.sort(samples)
    Enum.at(sorted, div(length(sorted), 2))
  end
end
