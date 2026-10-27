defmodule StreamDoctor.OptionsParser.Input do
  @moduledoc """
  Turns the `input` field of a streamer request into what the sender pipeline needs to build
  its ingest, rejecting anything it cannot honour before the pipeline starts.
  """

  alias StreamDoctor.OptionsParser.Input.Synthetic

  @type t :: {:file, String.t()} | {:synthetic, Synthetic.t()}

  @keys ~w(file synthetic)

  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(%{"file" => _path, "synthetic" => _config}) do
    {:error, "input takes either file or synthetic, not both"}
  end

  def parse(%{"file" => path} = input) when is_binary(path) do
    with :ok <- known_keys(input) do
      {:ok, {:file, path}}
    end
  end

  def parse(%{"synthetic" => config} = input) do
    with :ok <- known_keys(input),
         {:ok, synthetic} <- Synthetic.parse(config) do
      {:ok, {:synthetic, synthetic}}
    end
  end

  def parse(%{"file" => _other}), do: {:error, "input.file must be a string"}

  def parse(_other) do
    {:error, ~s(input must be an object like {"file": "clip.mp4"} or {"synthetic": {}})}
  end

  defp known_keys(input) do
    case Map.keys(input) -- @keys do
      [] ->
        :ok

      [key | _] ->
        {:error, "input.#{key} is not a known setting; expected #{Enum.join(@keys, ", ")}"}
    end
  end

  @spec summary(t()) :: %{file: String.t()} | %{synthetic: Synthetic.t()}
  def summary({:file, path}), do: %{file: path}
  def summary({:synthetic, config}), do: %{synthetic: config}
end
