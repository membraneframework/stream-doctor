defmodule StreamDoctor.Metric.Latency do
  @moduledoc """
  End-to-end latency: matches `:video_frame_received` against
  `:video_frame_sent` by frame number; latency = receive time - send time
  (both on the owner's monotonic clock).

  Frame numbers wrap at `StreamDoctor.Probe.VideoMarkerDecoder.max_frame()`, so the send-time map
  is bounded (a new send overwrites the old slot).

  Modes (`:mode` option):

    * `:segment` (default) - for HLS viewers, which decode unpaced so frames
      arrive in per-segment batches: the reported `latency_ms` is the latency
      of the first frame of the latest segment (a >500 ms pause in arrival
      marks a new segment),
    * `:latest` - for players sampled by screenshots: `latency_ms` is the
      latency of the most recent matched frame.
  """

  @behaviour StreamDoctor.Metric

  # a pause in frame arrival longer than this marks the start of a new
  # segment batch (an unpaced viewer decodes a whole segment back-to-back,
  # then waits ~a segment duration for the next one)
  @segment_gap_ms 500
  @max_samples 50

  @impl true
  def name(), do: :latency

  @impl true
  def init(opts) do
    %{
      mode: Keyword.get(opts, :mode, :segment),
      sent_at: %{},
      samples: [],
      segment_latencies: [],
      segments_seen: 0,
      last_recv_t: nil,
      frames_matched: 0,
      frames_unmatched: 0,
      frames_undecoded: 0
    }
  end

  @impl true
  def handle_event({:video_frame_sent, n, t}, state), do: put_in(state.sent_at[n], t)

  def handle_event({:video_frame_received, n, _pts_ms, t}, state) do
    case state.sent_at[n] do
      nil ->
        %{state | frames_unmatched: state.frames_unmatched + 1}

      sent_t ->
        latency = t - sent_t

        first_of_segment? =
          state.last_recv_t == nil or t - state.last_recv_t > @segment_gap_ms

        segment_latencies =
          if first_of_segment?,
            do: Enum.take([latency | state.segment_latencies], @max_samples),
            else: state.segment_latencies

        %{
          state
          | last_recv_t: t,
            segments_seen: state.segments_seen + if(first_of_segment?, do: 1, else: 0),
            segment_latencies: segment_latencies,
            samples: Enum.take([{n, latency} | state.samples], @max_samples),
            frames_matched: state.frames_matched + 1
        }
    end
  end

  def handle_event({:undecoded, :video, _reason, _t}, state),
    do: %{state | frames_undecoded: state.frames_undecoded + 1}

  def handle_event(_event, state), do: state

  @impl true
  def report(state) do
    common = %{
      latency_ms: latency_ms(state),
      frames_matched: state.frames_matched,
      frames_unmatched: state.frames_unmatched,
      frames_undecoded: state.frames_undecoded,
      latest_samples:
        state.samples
        |> Enum.take(10)
        |> Enum.map(fn {n, latency} -> %{frame: n, latency_ms: latency} end)
    }

    case state.mode do
      :segment ->
        Map.merge(common, %{
          segments_seen: state.segments_seen,
          segment_latencies: state.segment_latencies
        })

      :latest ->
        common
    end
  end

  defp latency_ms(%{mode: :segment} = state), do: List.first(state.segment_latencies)

  defp latency_ms(%{mode: :latest} = state) do
    case state.samples do
      [{_n, latency} | _rest] -> latency
      [] -> nil
    end
  end
end
