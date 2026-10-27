defmodule StreamDoctor.OptionsParser.Options do
  @moduledoc """
  Runs a `NimbleOptions` schema against the string-keyed maps that arrive as JSON.
  """

  @spec validate(term(), keyword(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def validate(config, schema, scope) when is_map(config) do
    with {:ok, options} <- options(config, schema, scope) do
      case NimbleOptions.validate(options, schema) do
        {:ok, validated} -> {:ok, Map.new(validated)}
        {:error, error} -> {:error, "#{scope}: #{Exception.message(error)}"}
      end
    end
  end

  def validate(_other, _schema, scope), do: {:error, "#{scope} must be an object"}

  # Only keys the schema names become atoms, so a request cannot fill the atom table.
  defp options(config, schema, scope) do
    case Enum.find(Map.keys(config), &(declared(&1, schema) == nil)) do
      nil -> {:ok, Enum.map(config, &option(&1, schema))}
      key -> {:error, "#{scope}.#{key} is not a known setting; expected #{known(schema)}"}
    end
  end

  defp option({key, value}, schema) do
    {name, spec} = declared(key, schema)

    {name, coerce(value, spec[:type])}
  end

  defp declared(key, schema), do: Enum.find(schema, &(&1 |> elem(0) |> Atom.to_string() == key))

  defp known(schema), do: Enum.map_join(schema, ", ", &elem(&1, 0))

  defp coerce(value, {:in, choices}) when is_binary(value) do
    Enum.find(choices, value, &(is_atom(&1) and Atom.to_string(&1) == value))
  end

  defp coerce(value, _type), do: value
end
