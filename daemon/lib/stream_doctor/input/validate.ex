defmodule StreamDoctor.Input.Validate do
  @moduledoc """
  Checks for the settings of a synthetic input.
  """

  @spec known_keys(map(), [String.t()], String.t()) :: :ok | {:error, String.t()}
  def known_keys(config, allowed, path) do
    case Map.keys(config) -- allowed do
      [] -> :ok
      [key | _] -> {:error, "#{path}.#{key} is not a known setting; expected #{list(allowed)}"}
    end
  end

  @spec member(map(), String.t(), [atom()], String.t()) ::
          {:ok, atom() | nil} | {:error, String.t()}
  def member(config, key, allowed, path) do
    case Map.get(config, key) do
      nil ->
        {:ok, nil}

      value ->
        case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
          nil -> {:error, "#{path}.#{key} must be one of #{list(allowed)}, got #{inspect(value)}"}
          found -> {:ok, found}
        end
    end
  end

  @doc "True for an even integer inside `range`, as video dimensions must be."
  @spec even_in?(term(), Range.t()) :: boolean()
  def even_in?(value, range), do: is_integer(value) and value in range and rem(value, 2) == 0

  @doc "An optional integer setting, bounded by `range`."
  @spec optional_int(map(), String.t(), Range.t(), String.t()) ::
          {:ok, integer() | nil} | {:error, String.t()}
  def optional_int(config, key, %Range{first: first, last: last} = range, path) do
    value = Map.get(config, key)

    cond do
      value == nil ->
        {:ok, nil}

      is_integer(value) and value in range ->
        {:ok, value}

      true ->
        {:error, "#{path}.#{key} must be an integer in #{first}..#{last}, got #{inspect(value)}"}
    end
  end

  @spec list(Enumerable.t()) :: String.t()
  def list(values), do: Enum.map_join(values, ", ", &to_string/1)
end
