defmodule StreamDoctor.Metric.Frames do
  @moduledoc """
  Reports what happened to each track's sequence of decoded numbers, under `video` and `audio`, in three groups:

    * `reordered` - the numbers that arrived in the wrong order, with actual permutations and how deep the reordering went
    * `missing` - the numbers that never arrived, as inclusive ranges
    * `duplicated` - the numbers that arrived more than once, with how many extra times each did

  For example, if the viewer saw frames 110, 111, 112, 112, 116 the `video` report would be:
      %{
        reordered: %{count: 1, max_depth: 1, permutations: [[111, 110, 112]]},
        missing: %{count: 3, gaps: [[113, 115]]},
        duplicated: %{count: 1, repeats: [[112, 1]]}
      }
  """

  @behaviour StreamDoctor.Metric

  alias StreamDoctor.Metric
  alias StreamDoctor.Probe.Audio.Tone
  alias StreamDoctor.Probe.Video.Bar

  # How far the infrastructure may displace a frame before it counts as loss, not reordering.
  @reorder_depth 16
  @settle_lag 2 * @reorder_depth

  @evidence 10

  @impl true
  def name do
    :frames
  end

  @impl true
  def new(_opts) do
    %{video: new_track(Bar.max_frame()), audio: new_track(Tone.max_symbol())}
  end

  @impl true
  def record({:video_frame_received, frame_number, _pts}, state) do
    Map.update!(state, :video, &see_number(&1, frame_number))
  end

  @impl true
  def record({:audio_symbol_received, symbol_number, _pts}, state) do
    Map.update!(state, :audio, &see_number(&1, symbol_number))
  end

  @impl true
  def record(_event, state) do
    state
  end

  @impl true
  def report(state) do
    %{video: track_report(state.video), audio: track_report(state.audio)}
  end

  defp new_track(max) do
    %{
      max: max,
      previous: nil,
      highest: nil,
      join: nil,
      open_permutation: nil,
      seen: MapSet.new(),
      reordered: %{count: 0, max_depth: nil, permutations: []},
      missing: %{count: 0, gaps: []},
      duplicated: %{count: 0, repeats: []}
    }
  end

  defp see_number(track, wrapped_number) do
    number = Metric.unwrap(wrapped_number, track.previous, track.max)

    track
    |> count_descent(number)
    |> count_missing_and_duplicated(number)
    |> collect_permutations(number)
    |> advance_cursors(number)
  end

  defp track_report(%{previous: nil}) do
    %{
      reordered: %{count: nil, max_depth: nil, permutations: []},
      missing: %{count: nil, gaps: []},
      duplicated: %{count: nil, repeats: []}
    }
  end

  defp track_report(track) do
    %{
      reordered: %{track.reordered | permutations: permutations_so_far(track)},
      missing: settle(track, track.highest).missing,
      duplicated: track.duplicated
    }
  end

  defp advance_cursors(track, number) do
    %{track | previous: number, highest: max(number, track.highest || number)}
  end

  defp count_descent(%{previous: previous} = track, number)
       when previous != nil and number < previous do
    %{track | reordered: record_descent(track.reordered, previous - number)}
  end

  defp count_descent(track, _number) do
    track
  end

  defp count_missing_and_duplicated(%{join: join} = track, number)
       when join == nil or (number < join and join - number <= @settle_lag) do
    see(%{track | join: number}, number)
  end

  defp count_missing_and_duplicated(%{highest: highest} = track, number)
       when number > highest do
    track
    |> settle(horizon(number))
    |> see(number)
  end

  defp count_missing_and_duplicated(track, number) do
    if settled?(track, number), do: duplicate(track, number), else: see(track, number)
  end

  defp settled?(track, number) do
    MapSet.member?(track.seen, number) or number <= horizon(track.highest)
  end

  defp see(track, number) do
    %{track | seen: MapSet.put(track.seen, number)}
  end

  defp horizon(number), do: number - @settle_lag

  defp settle(track, horizon) do
    track.join
    |> max(horizon(track.highest) + 1)
    |> Range.new(horizon, 1)
    |> Enum.reject(&MapSet.member?(track.seen, &1))
    |> Enum.reduce(track, fn lost, acc -> %{acc | missing: record_loss(acc.missing, lost)} end)
    |> forget_settled(horizon)
  end

  defp forget_settled(track, horizon) do
    %{track | seen: MapSet.filter(track.seen, &(&1 > horizon))}
  end

  defp duplicate(track, number) do
    %{track | duplicated: record_repeat(track.duplicated, number)}
  end

  defp record_descent(reordered, depth) do
    %{reordered | count: reordered.count + 1, max_depth: max(depth, reordered.max_depth || 0)}
  end

  defp record_loss(missing, number) do
    %{missing | count: missing.count + 1, gaps: extend_gap(missing.gaps, number)}
  end

  defp record_repeat(duplicated, number) do
    %{duplicated | count: duplicated.count + 1, repeats: extend_run(duplicated.repeats, number)}
  end

  defp extend_run(repeats, number) do
    case List.last(repeats) do
      [^number, times] -> List.replace_at(repeats, -1, [number, times + 1])
      _other -> keep_last(repeats, [number, 1])
    end
  end

  defp extend_gap(gaps, number) do
    case List.last(gaps) do
      [from] when number == from + 1 -> List.replace_at(gaps, -1, [from, number])
      [from, to] when number == to + 1 -> List.replace_at(gaps, -1, [from, number])
      _other -> keep_last(gaps, [number])
    end
  end

  defp collect_permutations(%{open_permutation: open, highest: highest} = track, number)
       when open != nil and number > highest do
    close_permutation(track, number)
  end

  defp collect_permutations(%{open_permutation: nil, highest: highest} = track, number)
       when highest != nil and number < highest do
    open_permutation(track, number)
  end

  defp collect_permutations(%{open_permutation: open} = track, number) when open != nil do
    %{track | open_permutation: [number | open]}
  end

  defp collect_permutations(track, _number) do
    track
  end

  # Entries go in newest first and are reversed when the permutation closes.
  defp open_permutation(track, number) do
    %{track | open_permutation: [number, track.highest]}
  end

  defp close_permutation(%{open_permutation: open} = track, number) do
    %{
      track
      | open_permutation: nil,
        reordered: record_permutation(track.reordered, Enum.reverse([number | open]))
    }
  end

  defp record_permutation(reordered, permutation) do
    %{reordered | permutations: keep_last(reordered.permutations, permutation)}
  end

  defp permutations_so_far(%{open_permutation: nil} = track) do
    track.reordered.permutations
  end

  defp permutations_so_far(track) do
    keep_last(track.reordered.permutations, Enum.reverse(track.open_permutation))
  end

  defp keep_last(kept, entry), do: Enum.take(kept ++ [entry], -@evidence)
end
