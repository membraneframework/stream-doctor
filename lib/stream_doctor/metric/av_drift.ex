defmodule StreamDoctor.Metric.AvDrift do
  @moduledoc """
  Audio/video desynchronization as a timestamp-syncing player would present
  it: how far the audio content is shifted against the video content at equal
  presentation timestamps.

  Both markers encode the sender's media position: video frame `n` is at
  `n * frame_duration`, audio symbol `m` at
  `m * #{StreamDoctor.Probe.AudioMarkerDecoder.symbol_ms()} ms`, and both
  tracks start at 0 together. On the receiver every decoded frame/symbol also
  carries the stream's presentation timestamp, so each track yields a stable
  offset `pts - media position` (constant while the tracks are aligned; the
  common part is the stream's timestamp origin). The drift is the difference
  of the two:

      drift_ms = (audio pts - m * symbol_ms) - (video pts - n * frame_duration)

  Positive drift = the audio content is later than the video content of the
  same timestamp (video leads / audio lags).

  Wall-clock arrival is deliberately not used: the two decoders hand over
  their tracks in bursts of different shape (the H264 decoder holds the tail
  of every segment until the next one, the audio decoder buffers while
  synchronizing to the marker), which would dominate any arrival-based
  comparison. A player syncs by timestamps, so timestamps are what counts.

  The frame duration is the timestamp step between consecutively numbered
  received frames. The audio counter wraps (`max_symbol * symbol_ms` =
  3.84 s) and is unwrapped by continuity; the initial ambiguity is resolved
  against the video offset, so drift is resolved correctly up to ±half a
  cycle (±1.92 s). `drift_ms` is the median of the recent samples (one per
  audio symbol); `nil` until both tracks have been decoded.
  """

  @behaviour StreamDoctor.Metric

  alias StreamDoctor.Probe.AudioMarkerDecoder

  @max_samples 50

  @impl true
  def name(), do: :av_drift

  @impl true
  def init(_opts) do
    %{
      # last received video frame: {number, pts_ms}
      video: nil,
      frame_duration: nil,
      # pts - media position of the video track
      video_offset: nil,
      # unwrapped number of the last received audio symbol
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

  # First symbol: the cycle is picked so that the audio offset lands closest
  # to the video offset (|drift| < half a cycle). Later ones: closest to the
  # previous unwrapped number.
  defp unwrap(m, pts_ms, nil, video_offset) do
    cycle_ms = AudioMarkerDecoder.max_symbol() * AudioMarkerDecoder.symbol_ms()
    # media position the symbol should have for zero drift
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
