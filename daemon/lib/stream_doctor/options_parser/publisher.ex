defmodule StreamDoctor.OptionsParser.Publisher do
  @moduledoc """
  Turns the `input` field of a streamer request into what the sender pipeline needs to build
  its ingest, rejecting anything it cannot honour before the pipeline starts.
  """

  alias StreamDoctor.OptionsParser.Options
  alias StreamDoctor.OptionsParser.Publisher.Synthetic

  @type t :: {:file, String.t()} | {:synthetic, Synthetic.t()}

  @scope "input"

  defp schema do
    [
      file: [type: :string],
      synthetic: [type: {:custom, Synthetic, :object, []}]
    ]
  end

  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(config) do
    with {:ok, input} <- Options.validate(config, schema(), @scope) do
      variant(Map.get(input, :file), Map.get(input, :synthetic))
    end
  end

  defp variant(nil, nil) do
    {:error, ~s(input must name either file or synthetic, like {"file": "clip.mp4"})}
  end

  defp variant(file, synthetic) when file != nil and synthetic != nil do
    {:error, "input takes either file or synthetic, not both"}
  end

  defp variant(file, nil), do: {:ok, {:file, file}}

  defp variant(nil, synthetic) do
    with {:ok, config} <- Synthetic.parse(synthetic) do
      {:ok, {:synthetic, config}}
    end
  end

  @spec summary(t()) :: %{file: String.t()} | %{synthetic: Synthetic.t()}
  def summary({:file, path}), do: %{file: path}
  def summary({:synthetic, config}), do: %{synthetic: config}
end
