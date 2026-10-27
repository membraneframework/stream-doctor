defmodule StreamDoctor.OptionsParser.Input.Synthetic do
  @moduledoc """
  Parses the settings of a synthetic input.
  """

  alias StreamDoctor.OptionsParser.Input.Synthetic.{Audio, Video}
  alias StreamDoctor.OptionsParser.Options

  @type t :: %{video: Video.t(), audio: Audio.t(), duration: pos_integer() | nil}

  @scope "synthetic"

  @spec schema() :: keyword()
  def schema do
    [
      video: [type: {:custom, __MODULE__, :object, []}, default: %{}],
      audio: [type: {:custom, __MODULE__, :object, []}, default: %{}],
      duration: [type: :pos_integer]
    ]
  end

  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(config) do
    with {:ok, synthetic} <- Options.validate(config, schema(), @scope),
         {:ok, video} <- Video.parse(synthetic.video),
         {:ok, audio} <- Audio.parse(synthetic.audio) do
      {:ok, %{video: video, audio: audio, duration: Map.get(synthetic, :duration)}}
    end
  end

  @doc false
  @spec object(term()) :: {:ok, map()} | {:error, String.t()}
  def object(value) when is_map(value), do: {:ok, value}
  def object(value), do: {:error, "must be an object, got #{inspect(value)}"}
end
