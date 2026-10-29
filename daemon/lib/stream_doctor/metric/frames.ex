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
      peak: nil,
      first: nil,
      out_of_order: 0,
      max_depth: nil,
      group: nil,
      permutations: [],
      holes: [],
      missing: 0,
      gaps: [],
      duplicated: 0,
      repeats: []
    }
  end

  @impl true
  def handle_event({:video_frame_received, frame_number, _pts}, state) do
    number = Metric.unwrap(frame_number, state.previous, MarkerDecoder.max_frame())

    state
    |> count_descent(number)
    |> account(number)
    |> regroup(number)
    |> advance(number)
    |> Map.put(:previous, number)
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
    drained = settle(state, state.peak + 1)

    %{
      reordered: %{
        count: state.out_of_order,
        max_depth: state.max_depth,
        permutations: keep(state.permutations, state.group && Enum.reverse(state.group))
      },
      missing: %{count: drained.missing, gaps: drained.gaps},
      duplicated: %{count: state.duplicated, repeats: state.repeats}
    }
  end

  defp advance(%{peak: peak} = state, number) when peak == nil or number > peak do
    %{state | peak: number}
  end

  defp advance(state, _number) do
    state
  end

  defp count_descent(%{previous: previous} = state, number)
       when previous != nil and number < previous do
    %{
      state
      | out_of_order: state.out_of_order + 1,
        max_depth: max(previous - number, state.max_depth || 0)
    }
  end

  defp count_descent(state, _number) do
    state
  end

  defp account(%{first: nil} = state, number) do
    %{state | first: number}
  end

  defp account(%{peak: peak} = state, number) when number > peak do
    state |> owe(peak + 1, number - 1) |> settle(number - @settle_lag)
  end

  defp account(%{first: first} = state, number)
       when number < first and first - number <= @settle_lag do
    %{state | first: number}
  end

  defp account(state, number) do
    case claim(state.holes, number) do
      {:ok, holes} -> %{state | holes: holes}
      :absent -> duplicate(state, number)
    end
  end

  defp owe(state, from, to) when from > to do
    state
  end

  defp owe(state, from, to) do
    %{state | holes: state.holes ++ [{from, to}]}
  end

  # Runs above the horizon are disjoint and need a frame between them, so the list stays bounded.
  defp settle(%{holes: [{from, to} | rest]} = state, horizon) when to < horizon do
    %{
      state
      | holes: rest,
        missing: state.missing + to - from + 1,
        gaps: keep(state.gaps, gap(from, to))
    }
    |> settle(horizon)
  end

  defp settle(state, _horizon) do
    state
  end

  defp claim([{from, to} | rest], number) when from <= number and number <= to do
    {:ok, split(from, to, number) ++ rest}
  end

  defp claim([hole | rest], number) do
    with {:ok, holes} <- claim(rest, number), do: {:ok, [hole | holes]}
  end

  defp claim([], _number) do
    :absent
  end

  defp split(from, to, number) do
    Enum.reject([{from, number - 1}, {number + 1, to}], fn {from, to} -> from > to end)
  end

  defp duplicate(state, number) do
    %{state | duplicated: state.duplicated + 1, repeats: repeat(state.repeats, number)}
  end

  defp repeat(repeats, number) do
    case List.last(repeats) do
      [^number, times] -> List.replace_at(repeats, -1, [number, times + 1])
      _other -> keep(repeats, [number, 1])
    end
  end

  defp gap(number, number), do: [number]
  defp gap(from, to), do: [from, to]

  # A frame above the peak ends the reordering it ran into, and is kept as its last element.
  defp regroup(%{peak: peak} = state, number) when peak == nil or number > peak do
    permutation = state.group && Enum.reverse([number | state.group])

    %{state | group: nil, permutations: keep(state.permutations, permutation)}
  end

  defp regroup(%{group: nil, peak: peak} = state, number) when number < peak do
    %{state | group: [number, state.previous]}
  end

  defp regroup(%{group: group} = state, number)
       when group != nil and length(group) < @frames_per_permutation - 1 do
    %{state | group: [number | group]}
  end

  defp regroup(state, _number) do
    state
  end

  defp keep(kept, nil), do: kept
  defp keep(kept, entry), do: Enum.take(kept ++ [entry], -@evidence)
end
