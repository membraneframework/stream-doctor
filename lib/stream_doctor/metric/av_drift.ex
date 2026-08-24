defmodule StreamDoctor.Metric.AvDrift do
  @moduledoc """
  Audio/video desynchronization, computed from the marker counters alone.

  Both counters encode the sender's media position: video frame `n` was at
  `n * frame_duration`, audio symbol `m` at
  `m * #{StreamDoctor.Probe.AudioMarkerDecoder.symbol_ms()} ms`, and both
  start at 0 together. Whenever either counter advances, the drift is the
  difference of the media positions the two tracks have reached:

      drift_ms = n * frame_duration - m * symbol_ms

  Positive drift = the decoded video is further into the media than the
  decoded audio (video leads).

  The counters wrap (`StreamDoctor.Probe.VideoMarkerDecoder.max_frame()`,
  `StreamDoctor.Probe.AudioMarkerDecoder.max_symbol()`) and are unwrapped by
  continuity. The video frame duration is not carried by the marker; it is
  calibrated from the counters themselves - over the same receive window both
  tracks cover the same media time span, so
  `frame_duration = symbol_ms * Δm / Δn` - once at least
  #{60} video frames have been observed. Until then `drift_ms` is `nil`.

  A single comparison is noisy: the two decoders are at slightly different
  stream positions at any instant (segment-batched, concurrent decoding), so
  the reported `drift_ms` is the median of the recent samples.
  """

  @behaviour StreamDoctor.Metric

  alias StreamDoctor.Probe.{AudioMarkerDecoder, VideoMarkerDecoder}

  @max_samples 50
  # video frames needed before the frame duration (and thus drift) is reported
  @calibration_frames 60

  @impl true
  def name(), do: :av_drift

  @impl true
  def init(_opts) do
    %{video: nil, video_first: nil, audio: nil, audio_first: nil, samples: []}
  end

  @impl true
  def handle_event({:video_frame_received, n, _pts_ms, _t}, state) do
    n = unwrap(n, state.video, VideoMarkerDecoder.max_frame())

    %{state | video: n, video_first: state.video_first || n}
    |> compute()
  end

  def handle_event({:audio_symbol_received, m, _pts_ms, _t}, state) do
    m = unwrap(m, state.audio, AudioMarkerDecoder.max_symbol())

    %{state | audio: m, audio_first: state.audio_first || m}
    |> compute()
  end

  def handle_event(_event, state), do: state

  @impl true
  def report(state) do
    frame_duration = frame_duration(state)

    %{
      drift_ms: median(state.samples),
      frame_duration_ms: frame_duration && Float.round(frame_duration, 2),
      latest_samples: Enum.take(state.samples, 10)
    }
  end

  # Unwraps a counter that wraps at `max` by picking the value closest to the
  # previous (unwrapped) one.
  defp unwrap(n, nil, _max), do: n

  defp unwrap(n, last, max) do
    candidate = div(last, max) * max + n

    cond do
      candidate < last - div(max, 2) -> candidate + max
      candidate > last + div(max, 2) -> candidate - max
      true -> candidate
    end
  end

  defp compute(state) do
    case frame_duration(state) do
      nil ->
        state

      frame_duration ->
        drift = state.video * frame_duration - state.audio * AudioMarkerDecoder.symbol_ms()
        %{state | samples: Enum.take([round(drift) | state.samples], @max_samples)}
    end
  end

  defp frame_duration(%{video: n, video_first: n0, audio: m, audio_first: m0})
       when n != nil and m != nil and n - n0 >= @calibration_frames and m > m0 do
    AudioMarkerDecoder.symbol_ms() * (m - m0) / (n - n0)
  end

  defp frame_duration(_state), do: nil

  defp median([]), do: nil

  defp median(samples) do
    sorted = Enum.sort(samples)
    Enum.at(sorted, div(length(sorted), 2))
  end
end
