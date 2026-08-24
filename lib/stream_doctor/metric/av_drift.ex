defmodule StreamDoctor.Metric.AvDrift do
  @moduledoc """
  Audio/video desynchronization, measured entirely on the receiver side.

  Both markers encode the sender's media position: video frame `n` was at
  sender position `n * frame_duration`, audio symbol `m` at
  `m * #{StreamDoctor.Probe.AudioMarkerDecoder.symbol_ms()} ms`. For each track the offset
  `pts - sender_position` is constant when the stream is intact; the drift is
  the difference of the two offsets:

      drift_ms = (video_pts - n * frame_duration) - (audio_pts - m * symbol_ms)

  Positive drift = the video track sits later on the receiver timeline than
  the audio track for the same content (audio leads).

  The marker counters wrap (`StreamDoctor.Probe.VideoMarkerDecoder.max_frame()`,
  `StreamDoctor.Probe.AudioMarkerDecoder.max_symbol()`) and are unwrapped by continuity, and the
  video frame duration is not carried by the marker, so it is estimated as an
  exponential moving average of `pts delta / frame-number delta` between
  consecutive decoded frames. Events without a `pts_ms` (e.g. player
  screenshots) are ignored.
  """

  @behaviour StreamDoctor.Metric

  alias StreamDoctor.Probe.{AudioMarkerDecoder, VideoMarkerDecoder}

  @max_samples 50
  # EMA weight of a new frame-duration observation
  @ema_alpha 0.1

  @impl true
  def name(), do: :av_drift

  @impl true
  def init(_opts) do
    %{video: nil, audio: nil, frame_duration_ms: nil, drift_ms: nil, samples: []}
  end

  @impl true
  def handle_event({:video_frame_received, n, pts_ms, _t}, state) when pts_ms != nil do
    n = unwrap(n, state.video, VideoMarkerDecoder.max_frame())

    state
    |> update_frame_duration(n, pts_ms)
    |> Map.put(:video, {n, pts_ms})
    |> compute()
  end

  def handle_event({:audio_symbol_received, m, pts_ms, _t}, state) when pts_ms != nil do
    m = unwrap(m, state.audio, AudioMarkerDecoder.max_symbol())

    state
    |> Map.put(:audio, {m, pts_ms})
    |> compute()
  end

  def handle_event(_event, state), do: state

  @impl true
  def report(state) do
    %{
      drift_ms: state.drift_ms && round(state.drift_ms),
      frame_duration_ms: state.frame_duration_ms && Float.round(state.frame_duration_ms, 2),
      latest_samples: Enum.take(state.samples, 10)
    }
  end

  # Unwraps a counter that wraps at `max` by picking the value closest to the
  # previous (unwrapped) one.
  defp unwrap(n, nil, _max), do: n

  defp unwrap(n, {last, _pts}, max) do
    candidate = div(last, max) * max + n

    cond do
      candidate < last - div(max, 2) -> candidate + max
      candidate > last + div(max, 2) -> candidate - max
      true -> candidate
    end
  end

  defp update_frame_duration(%{video: {last_n, last_pts}} = state, n, pts_ms)
       when n > last_n and pts_ms > last_pts do
    observed = (pts_ms - last_pts) / (n - last_n)

    frame_duration =
      case state.frame_duration_ms do
        nil -> observed
        current -> current * (1 - @ema_alpha) + observed * @ema_alpha
      end

    %{state | frame_duration_ms: frame_duration}
  end

  defp update_frame_duration(state, _n, _pts_ms), do: state

  defp compute(%{video: {n, vpts}, audio: {m, apts}, frame_duration_ms: fd} = state)
       when fd != nil do
    drift = vpts - n * fd - (apts - m * AudioMarkerDecoder.symbol_ms())
    %{state | drift_ms: drift, samples: Enum.take([round(drift) | state.samples], @max_samples)}
  end

  defp compute(state), do: state
end
