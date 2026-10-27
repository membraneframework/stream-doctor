defmodule StreamDoctor.Metric.FrameOrder do
  @moduledoc """
  Counts how often decoded frame numbers go backwards, which means the stream reordered frames,
  and keeps the arrival order of the first few so the permutation can be read back.

  Gaps and repeats are left alone - they come from unreadable markers, skipped segments and from
  rounding. Marker numbers are the source pts divided by the frame duration, so a variable frame
  rate makes them move backwards on its own; the counts are only meaningful for a constant one.
  """

  @behaviour StreamDoctor.Metric

  alias StreamDoctor.Metric
  alias StreamDoctor.Probe.Video.MarkerDecoder

  # H.264 reorders by at most 16 frames, so a longer run is not the codec, and its tail says
  # nothing max_depth does not already carry.
  @frames_per_permutation 32
  @permutations 10

  @impl true
  def name do
    :frame_order
  end

  @impl true
  def init(_opts) do
    %{previous: nil, peak: nil, out_of_order: 0, max_depth: nil, group: nil, permutations: []}
  end

  @impl true
  def handle_event({:video_frame_received, frame_number, _pts}, state) do
    number = Metric.unwrap(frame_number, state.previous, MarkerDecoder.max_frame())

    state
    |> count_descent(number)
    |> regroup(number)
    |> Map.put(:previous, number)
  end

  @impl true
  def handle_event(_event, state) do
    state
  end

  @impl true
  def report(%{previous: nil}) do
    %{out_of_order: nil, max_depth: nil, permutations: []}
  end

  def report(state) do
    %{
      out_of_order: state.out_of_order,
      max_depth: state.max_depth,
      permutations: keep(state, state.group && Enum.reverse(state.group))
    }
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

  # A frame above the peak ends the reordering it ran into, and is kept as its last element.
  defp regroup(%{peak: peak} = state, number) when peak == nil or number > peak do
    permutation = state.group && Enum.reverse([number | state.group])

    %{state | peak: number, group: nil, permutations: keep(state, permutation)}
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

  defp keep(state, nil), do: state.permutations
  defp keep(%{permutations: kept}, _permutation) when length(kept) >= @permutations, do: kept
  defp keep(state, permutation), do: state.permutations ++ [permutation]
end
