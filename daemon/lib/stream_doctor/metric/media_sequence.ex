defmodule StreamDoctor.Metric.MediaSequence do
  @evidence 10

  @moduledoc """
  Checks that the media playlist only moves forward, by comparing each read with the one before
  it.

  Returns a report with five fields:
    * `regressed` - how many times `EXT-X-MEDIA-SEQUENCE` went down
    * `skipped` - the segments the playlist moved past between two reads, so they were never seen listed
    * `replaced` - the segments whose URI changed while they kept their sequence number
    * `withdrawn` - the segments that disappeared from the end of the playlist
    * `latest_faults` - the #{@evidence} newest faults, each with its `fault` and the sequence numbers `from` and `to` it spans, which for `regressed` are the old and the new `EXT-X-MEDIA-SEQUENCE`
  """

  @behaviour StreamDoctor.Metric

  @impl true
  def name do
    :media_sequence
  end

  @impl true
  def new(_opts) do
    %{listed: nil, regressed: 0, skipped: 0, replaced: 0, withdrawn: 0, faults: []}
  end

  @impl true
  def record({:playlist_read, _at, %{} = listing}, %{listed: nil} = state) do
    %{state | listed: listing}
  end

  @impl true
  def record(
        {:playlist_read, _at, %{media_sequence: now} = listing},
        %{listed: %{media_sequence: before}} = state
      )
      when now < before do
    fault(%{state | listed: listing}, :regressed, 1, before, now)
  end

  @impl true
  def record({:playlist_read, _at, %{} = listing}, %{listed: listed} = state) do
    skipped_from = listed.newest + 1
    skipped_to = listing.media_sequence - 1
    withdrawn_from = listing.newest + 1

    replaced =
      for {number, uri} <- Enum.sort(listing.uris),
          Map.get(listed.uris, number, uri) != uri,
          do: number

    state = %{state | listed: listing}
    state = fault(state, :skipped, skipped_to - skipped_from + 1, skipped_from, skipped_to)

    state =
      fault(state, :withdrawn, listed.newest - listing.newest, withdrawn_from, listed.newest)

    Enum.reduce(replaced, state, &fault(&2, :replaced, 1, &1, &1))
  end

  @impl true
  def record(_event_of_another_metric, state) do
    state
  end

  @impl true
  def report(state) do
    state
    |> Map.take([:regressed, :skipped, :replaced, :withdrawn])
    |> Map.put(:latest_faults, state.faults)
  end

  defp fault(state, name, count, from, to) when count > 0 do
    entry = %{fault: name, from: from, to: to}

    state
    |> Map.update!(name, &(&1 + count))
    |> Map.update!(:faults, &Enum.take([entry | &1], @evidence))
  end

  defp fault(state, _name, _none, _from, _to) do
    state
  end
end
