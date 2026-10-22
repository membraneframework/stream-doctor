defmodule StreamDoctor.OptionsParser.Input do
  @moduledoc """
  Parses what a streamer should send: a file to read, or a synthetic source to generate.
  """

  alias StreamDoctor.OptionsParser.Input.Synthetic
  alias StreamDoctor.OptionsParser.Validate

  @type t :: {:file, String.t()} | {:synthetic, Synthetic.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(path) when is_binary(path), do: {:ok, {:file, path}}

  def parse(%{"synthetic" => config} = input) when is_map(config) do
    with :ok <- Validate.known_keys(input, ["synthetic"], "input"),
         {:ok, synthetic} <- Synthetic.parse(config) do
      {:ok, {:synthetic, synthetic}}
    end
  end

  def parse(_other) do
    {:error, ~s(input must be a file path or an object like {"synthetic": {}})}
  end

  @spec summary(t()) :: String.t() | %{synthetic: Synthetic.t()}
  def summary({:file, path}), do: path
  def summary({:synthetic, config}), do: %{synthetic: Synthetic.summary(config)}
end
