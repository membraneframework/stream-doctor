defmodule StreamDoctor.Metric.PlaylistAge do
  @evidence 10

  @moduledoc """
  Measures how long the media playlist goes without listing a new segment, against the target
  duration it declares. The age is counted from when watching began, and stops at `EXT-X-ENDLIST`.

  Returns a report with five fields:
    * `target_duration_ms` - the `EXT-X-TARGETDURATION` of the newest playlist read
    * `age_ms` - how long ago the newest segment appeared, as of the last reload
    * `max_age_ms` - the largest age seen
    * `stale` - how many times the age went past one and a half target durations
    * `latest_samples` - the ages at which the #{@evidence} newest segments appeared
  """

  @behaviour StreamDoctor.Metric

  @impl true
  def name do
    :playlist_age
  end

  @impl true
  def new(_opts) do
    %{
      target_ms: nil,
      newest: nil,
      changed_at: nil,
      age_ms: nil,
      max_age_ms: nil,
      stale: 0,
      stale?: false,
      ended?: false,
      samples: []
    }
  end

  @impl true
  def record({:playlist_read, _at, _listing}, %{ended?: true} = state) do
    state
  end

  @impl true
  def record({:playlist_read, _at, :ended}, state) do
    %{state | ended?: true}
  end

  @impl true
  def record({:playlist_read, at, %{} = listing}, %{changed_at: nil} = state) do
    %{
      state
      | target_ms: listing.target_duration_ms,
        newest: listing.newest,
        changed_at: at,
        age_ms: 0,
        max_age_ms: 0
    }
  end

  @impl true
  def record({:playlist_read, _at, :unreadable}, %{changed_at: nil} = state) do
    state
  end

  @impl true
  def record({:playlist_read, at, %{newest: newest} = listing}, %{newest: listed} = state)
      when newest != listed do
    state = age(%{state | target_ms: listing.target_duration_ms}, at)

    %{
      state
      | newest: newest,
        changed_at: at,
        age_ms: 0,
        stale?: false,
        samples: Enum.take([state.age_ms | state.samples], @evidence)
    }
  end

  @impl true
  def record({:playlist_read, at, _nothing_new}, state) do
    age(state, at)
  end

  @impl true
  def record(_event_of_another_metric, state) do
    state
  end

  @impl true
  def report(state) do
    %{
      target_duration_ms: state.target_ms,
      age_ms: state.age_ms,
      max_age_ms: state.max_age_ms,
      stale: state.stale,
      latest_samples: state.samples
    }
  end

  defp age(state, at) do
    age_ms = at - state.changed_at
    # RFC 8216 gives the server one and a half target durations to list the next segment.
    stale? = 2 * age_ms > 3 * state.target_ms
    stale = if stale? and not state.stale?, do: state.stale + 1, else: state.stale

    %{
      state
      | age_ms: age_ms,
        max_age_ms: max(state.max_age_ms, age_ms),
        stale: stale,
        stale?: stale?
    }
  end
end
