defmodule StreamDoctor.Metric.AvDrift do
  @moduledoc """
  Measures A/V desync the way a pts-syncing player would see it:

      drift = (audio pts - symbol_number * symbol duration) - (video pts - frame_number * frame duration)

  Positive result means that audio content is later than video.
  """

  @behaviour StreamDoctor.Metric

  alias StreamDoctor.Probe.Audio.MarkerDecoder, as: AudioMarkerDecoder
  alias StreamDoctor.Probe.Video.MarkerDecoder, as: VideoMarkerDecoder

  @max_samples 50

  @impl true
  def name do
    :av_drift
  end

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
  def handle_event({:video_frame_received, _frame_number, _pts = nil}, state) do
    state
  end

  @impl true
  def handle_event({:video_frame_received, frame_number, pts}, state) do
    frame_number = unwrap(frame_number, state.video, VideoMarkerDecoder.max_frame())
    {first_frame_number, first_pts} = state.video_first || {frame_number, pts}

    frame_duration =
      if frame_number > first_frame_number and pts > first_pts,
        do: div(pts - first_pts, frame_number - first_frame_number),
        else: state.frame_duration

    video_offset = frame_duration && pts - frame_number * frame_duration

    %{
      state
      | video_first: {first_frame_number, first_pts},
        video: frame_number,
        frame_duration: frame_duration,
        video_offset: video_offset
    }
  end

  @impl true
  def handle_event({:audio_symbol_received, _symbol_number, _pts = nil}, state) do
    state
  end

  @impl true
  def handle_event(
        {:audio_symbol_received, symbol_number, pts},
        %{video_offset: video_offset} = state
      )
      when video_offset != nil do
    symbol_number =
      case state.audio do
        nil -> unwrap_against_video(symbol_number, pts, video_offset)
        last -> unwrap(symbol_number, last, AudioMarkerDecoder.max_symbol())
      end

    drift = round(pts - symbol_number * symbol_duration() - video_offset)
    %{state | audio: symbol_number, samples: Enum.take([drift | state.samples], @max_samples)}
  end

  @impl true
  def handle_event(_event, state) do
    state
  end

  @impl true
  def report(state) do
    %{
      drift_ms: state.samples |> median() |> to_ms(),
      frame_duration_ms: to_ms(state.frame_duration),
      latest_samples: state.samples |> Enum.take(10) |> Enum.map(&to_ms/1)
    }
  end

  defp unwrap_against_video(symbol_number, pts, video_offset) do
    max = AudioMarkerDecoder.max_symbol()

    k =
      round((pts - video_offset - symbol_number * symbol_duration()) / (max * symbol_duration()))

    symbol_number + k * max
  end

  defp unwrap(value, nil, _max) do
    value
  end

  defp unwrap(value, last, max) do
    candidate = Integer.floor_div(last, max) * max + value

    cond do
      candidate < last - div(max, 2) -> candidate + max
      candidate > last + div(max, 2) -> candidate - max
      true -> candidate
    end
  end

  defp symbol_duration do
    Membrane.Time.milliseconds(AudioMarkerDecoder.symbol_ms())
  end

  defp median([]) do
    nil
  end

  defp median(samples) do
    sorted = Enum.sort(samples)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp to_ms(nil) do
    nil
  end

  defp to_ms(time) do
    Membrane.Time.as_milliseconds(time, :round)
  end
end
