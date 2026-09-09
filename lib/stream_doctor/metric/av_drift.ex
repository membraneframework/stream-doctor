defmodule StreamDoctor.Metric.AvDrift do
  @moduledoc """
  A/V desync the way a pts-syncing player would see it:

      drift = (audio pts - m * symbol duration) - (video pts - n * frame duration)

  Positive = audio content later than video. The sender numbers frames and
  symbols by their source pts, so each term is the received pts of source
  time zero and their difference is the desync. Arrival times are useless
  here (decoders burst differently), so only timestamps are used. The frame
  duration is fitted between the first and the latest frame: a value rounded
  to the millisecond, multiplied by n, would be seconds off within a minute.
  Counters wrap (audio every 3.84 s, unwrapped against the video offset, so
  good up to ±1.92 s; video every 16384 frames, which a viewer joining after
  the first wrap can't tell apart from zero, so join within 9 min of the
  stream start at 30 fps). Reported value is a median.
  """

  @behaviour StreamDoctor.Metric

  alias StreamDoctor.Probe.Audio.MarkerDecoder, as: AudioMarkerDecoder
  alias StreamDoctor.Probe.Video.MarkerDecoder, as: VideoMarkerDecoder

  @max_samples 50

  @impl true
  def name(), do: :av_drift

  @impl true
  def init(_opts) do
    %{
      video_first: nil,
      video: nil,
      frame_duration: nil,
      video_offset: nil,
      audio: nil,
      samples: []
    }
  end

  @impl true
  def handle_event({:video_frame_received, _n, nil, _t}, state), do: state

  def handle_event({:video_frame_received, n, pts, _t}, state) do
    n = unwrap(n, state.video, VideoMarkerDecoder.max_frame())
    {first_n, first_pts} = state.video_first || {n, pts}

    frame_duration =
      if n > first_n and pts > first_pts,
        do: (pts - first_pts) / (n - first_n),
        else: state.frame_duration

    video_offset = frame_duration && pts - n * frame_duration

    %{
      state
      | video_first: {first_n, first_pts},
        video: n,
        frame_duration: frame_duration,
        video_offset: video_offset
    }
  end

  def handle_event({:audio_symbol_received, _m, nil, _t}, state), do: state

  def handle_event({:audio_symbol_received, m, pts, _t}, %{video_offset: video_offset} = state)
      when video_offset != nil do
    m =
      case state.audio do
        nil -> unwrap_against_video(m, pts, video_offset)
        last -> unwrap(m, last, AudioMarkerDecoder.max_symbol())
      end

    drift = pts - m * symbol_duration() - video_offset
    %{state | audio: m, samples: Enum.take([drift | state.samples], @max_samples)}
  end

  def handle_event(_event, state), do: state

  @impl true
  def report(state) do
    %{
      drift_ms: state.samples |> median() |> to_ms(),
      frame_duration_ms: state.frame_duration && Float.round(state.frame_duration / 1_000_000, 2),
      latest_samples: state.samples |> Enum.take(10) |> Enum.map(&to_ms/1)
    }
  end

  defp unwrap_against_video(m, pts, video_offset) do
    max = AudioMarkerDecoder.max_symbol()
    k = round((pts - video_offset - m * symbol_duration()) / (max * symbol_duration()))
    m + k * max
  end

  defp unwrap(m, nil, _max), do: m

  defp unwrap(m, last, max) do
    candidate = Integer.floor_div(last, max) * max + m

    cond do
      candidate < last - div(max, 2) -> candidate + max
      candidate > last + div(max, 2) -> candidate - max
      true -> candidate
    end
  end

  defp symbol_duration(), do: Membrane.Time.milliseconds(AudioMarkerDecoder.symbol_ms())

  defp median([]), do: nil

  defp median(samples) do
    sorted = Enum.sort(samples)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp to_ms(nil), do: nil
  defp to_ms(time), do: round(time / 1_000_000)
end
