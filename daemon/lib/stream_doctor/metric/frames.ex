defmodule StreamDoctor.Metric.Frames do
  @moduledoc """
  Reports what happened to the sequence of decoded frame numbers: how often it went backwards,
  which numbers never arrived, and which arrived more than once.

  A verdict on a missing number is deferred, so a frame that merely runs late is not counted as
  lost. Marker numbers are the source pts divided by the frame duration, so a variable frame rate
  moves them on its own; every count here is only meaningful for a constant one.
  """

  @behaviour StreamDoctor.Metric

  alias StreamDoctor.Metric
  alias StreamDoctor.Probe.Video.MarkerDecoder

  # H.264 reorders by at most this, so a longer run is not the codec, and a number that has not
  # arrived within twice it is lost rather than late.
  @reorder_depth 16
  @frames_per_permutation 2 * @reorder_depth
  @settle_lag 2 * @reorder_depth

  @evidence 10

  @impl true
  def name do
    :frames
  end

  @impl true
  def init(_opts) do
    %{
      previous: nil,
      highest: nil,
      join: nil,
      open_permutation: nil,
      open_gaps: [],
      reordered: %{count: 0, max_depth: nil, permutations: []},
      missing: %{count: 0, gaps: []},
      duplicated: %{count: 0, repeats: []}
    }
  end

  @impl true
  def handle_event({:video_frame_received, frame_number, _pts}, state) do
    number = Metric.unwrap(frame_number, state.previous, MarkerDecoder.max_frame())

    state
    |> count_descent(number)
    |> count_missing_and_duplicated(number)
    |> collect_permutations(number)
    |> advance_cursors(number)
  end

  @impl true
  def handle_event(_event, state) do
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

  def report(state) do
    drained = close_gaps(state, state.highest + 1)

    %{
      reordered: %{state.reordered | permutations: permutations_so_far(state)},
      missing: drained.missing,
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
    %{state | join: number}
  end

  defp count_missing_and_duplicated(%{highest: highest} = state, number)
       when number > highest do
    state
    |> open_gap(highest + 1, number - 1)
    |> close_gaps(number - @settle_lag)
  end

  defp count_missing_and_duplicated(state, number) do
    case claim(state.open_gaps, number) do
      {:ok, open_gaps} -> %{state | open_gaps: open_gaps}
      :absent -> duplicate(state, number)
    end
  end

  defp open_gap(state, from, to) when from > to do
    state
  end

  defp open_gap(state, from, to) do
    %{state | open_gaps: state.open_gaps ++ [{from, to}]}
  end

  # Runs above the horizon are disjoint and need a frame between them, so the list stays bounded.
  defp close_gaps(%{open_gaps: [{from, to} | rest]} = state, horizon) when to < horizon do
    %{state | open_gaps: rest, missing: record_loss(state.missing, from, to)}
    |> close_gaps(horizon)
  end

  defp close_gaps(state, _horizon) do
    state
  end

  defp claim([{from, to} | rest], number) when from <= number and number <= to do
    {:ok, split(from, to, number) ++ rest}
  end

  defp claim([gap | rest], number) do
    with {:ok, open_gaps} <- claim(rest, number), do: {:ok, [gap | open_gaps]}
  end

  defp claim([], _number) do
    :absent
  end

  defp split(from, to, number) do
    Enum.reject([{from, number - 1}, {number + 1, to}], fn {from, to} -> from > to end)
  end

  defp duplicate(state, number) do
    %{state | duplicated: record_repeat(state.duplicated, number)}
  end

  defp record_descent(reordered, depth) do
    %{reordered | count: reordered.count + 1, max_depth: max(depth, reordered.max_depth || 0)}
  end

  defp record_loss(missing, from, to) do
    %{missing | count: missing.count + to - from + 1, gaps: keep(missing.gaps, gap(from, to))}
  end

  defp record_repeat(duplicated, number) do
    %{duplicated | count: duplicated.count + 1, repeats: extend_run(duplicated.repeats, number)}
  end

  defp extend_run(repeats, number) do
    case List.last(repeats) do
      [^number, times] -> List.replace_at(repeats, -1, [number, times + 1])
      _other -> keep(repeats, [number, 1])
    end
  end

  defp gap(number, number), do: [number]
  defp gap(from, to), do: [from, to]

  defp collect_permutations(%{highest: highest} = state, number)
       when highest == nil or number > highest do
    close_permutation(state, number)
  end

  defp collect_permutations(%{open_permutation: nil, highest: highest} = state, number)
       when number < highest do
    %{state | open_permutation: [number, state.previous]}
  end

  defp collect_permutations(%{open_permutation: open} = state, number)
       when open != nil and length(open) < @frames_per_permutation - 1 do
    %{state | open_permutation: [number | open]}
  end

  defp collect_permutations(state, _number) do
    state
  end

  defp close_permutation(%{open_permutation: nil} = state, _number) do
    state
  end

  defp close_permutation(%{open_permutation: open} = state, number) do
    %{
      state
      | open_permutation: nil,
        reordered: record_permutation(state.reordered, Enum.reverse([number | open]))
    }
  end

  defp record_permutation(reordered, permutation) do
    %{reordered | permutations: keep(reordered.permutations, permutation)}
  end

  defp permutations_so_far(%{open_permutation: nil} = state) do
    state.reordered.permutations
  end

  defp permutations_so_far(state) do
    keep(state.reordered.permutations, Enum.reverse(state.open_permutation))
  end

  defp keep(kept, entry), do: Enum.take(kept ++ [entry], -@evidence)
end
