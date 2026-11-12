defmodule StreamDoctor.Metric.Frames do
  @moduledoc """
  Reports what happened to the sequence of decoded frame numbers, in three groups:

    * `reordered` - the numbers that arrived in the wrong order, with actual permutations and how deep the reordering went
    * `missing` - the numbers that never arrived, as inclusive ranges
    * `duplicated` - the numbers that arrived more than once, with how many extra times each did

  For example, if the viewer saw frames 110, 111, 112, 112, 116 the report would be:
      %{
        reordered: %{count: 1, max_depth: 1, permutations: [[111, 110, 112]]},
        missing: %{count: 3, gaps: [[113, 115]]},
        duplicated: %{count: 1, repeats: [[112, 1]]}
      }
  """

  @behaviour StreamDoctor.Metric

  alias StreamDoctor.Metric
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
    %{
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

  @impl true
  def record({:video_frame_received, frame_number, _pts}, state) do
    number = Metric.unwrap(frame_number, state.previous, Bar.max_frame())

    state
    |> count_descent(number)
    |> count_missing_and_duplicated(number)
    |> collect_permutations(number)
    |> advance_cursors(number)
  end

  @impl true
  def record(_event, state) do
    state
  end

  @impl true
  def report(%{previous: nil}) do
    %{
      reordered: %{count: nil, max_depth: nil, permutations: []},
      missing: %{count: nil, gaps: []},
      duplicated: %{count: nil, repeats: []}
    }
  end

  @impl true
  def report(state) do
    %{
      reordered: %{state.reordered | permutations: permutations_so_far(state)},
      missing: settle(state, state.highest).missing,
      duplicated: state.duplicated
    }
  end

  defp advance_cursors(state, number) do
    %{state | previous: number, highest: max(number, state.highest || number)}
  end

  defp count_descent(%{previous: previous} = state, number)
       when previous != nil and number < previous do
    %{state | reordered: record_descent(state.reordered, previous - number)}
  end

  defp count_descent(state, _number) do
    state
  end

  defp count_missing_and_duplicated(%{join: join} = state, number)
       when join == nil or (number < join and join - number <= @settle_lag) do
    see(%{state | join: number}, number)
  end

  defp count_missing_and_duplicated(%{highest: highest} = state, number)
       when number > highest do
    state
    |> settle(horizon(number))
    |> see(number)
  end

  defp count_missing_and_duplicated(state, number) do
    if settled?(state, number), do: duplicate(state, number), else: see(state, number)
  end

  defp settled?(state, number) do
    MapSet.member?(state.seen, number) or number <= horizon(state.highest)
  end

  defp see(state, number) do
    %{state | seen: MapSet.put(state.seen, number)}
  end

  defp horizon(number), do: number - @settle_lag

  defp settle(state, horizon) do
    state.join
    |> max(horizon(state.highest) + 1)
    |> Range.new(horizon, 1)
    |> Enum.reject(&MapSet.member?(state.seen, &1))
    |> Enum.reduce(state, fn lost, acc -> %{acc | missing: record_loss(acc.missing, lost)} end)
    |> forget_settled(horizon)
  end

  defp forget_settled(state, horizon) do
    %{state | seen: MapSet.filter(state.seen, &(&1 > horizon))}
  end

  defp duplicate(state, number) do
    %{state | duplicated: record_repeat(state.duplicated, number)}
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

  defp collect_permutations(%{open_permutation: open, highest: highest} = state, number)
       when open != nil and number > highest do
    close_permutation(state, number)
  end

  defp collect_permutations(%{open_permutation: nil, highest: highest} = state, number)
       when highest != nil and number < highest do
    open_permutation(state, number)
  end

  defp collect_permutations(%{open_permutation: open} = state, number) when open != nil do
    %{state | open_permutation: [number | open]}
  end

  defp collect_permutations(state, _number) do
    state
  end

  # Entries go in newest first and are reversed when the permutation closes.
  defp open_permutation(state, number) do
    %{state | open_permutation: [number, state.highest]}
  end

  defp close_permutation(%{open_permutation: open} = state, number) do
    %{
      state
      | open_permutation: nil,
        reordered: record_permutation(state.reordered, Enum.reverse([number | open]))
    }
  end

  defp record_permutation(reordered, permutation) do
    %{reordered | permutations: keep_last(reordered.permutations, permutation)}
  end

  defp permutations_so_far(%{open_permutation: nil} = state) do
    state.reordered.permutations
  end

  defp permutations_so_far(state) do
    keep_last(state.reordered.permutations, Enum.reverse(state.open_permutation))
  end

  defp keep_last(kept, entry), do: Enum.take(kept ++ [entry], -@evidence)
end
