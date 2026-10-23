defmodule StreamDoctor.OptionsParser.Input.Synthetic do
  @moduledoc """
  Parses the settings of a synthetic input.
  """

  alias StreamDoctor.OptionsParser.Validate

  alias StreamDoctor.OptionsParser.Input.Synthetic.{Audio, Video}

  @type t :: %{video: Video.t(), audio: Audio.t(), duration: 1..86_400 | nil}

  @keys ~w(video audio duration)

  @max_duration 86_400

  @spec parse(map()) :: {:ok, t()} | {:error, String.t()}
  def parse(config) do
    with :ok <- Validate.known_keys(config, @keys, "synthetic"),
         {:ok, video} <- Video.parse(Map.get(config, "video", %{})),
         {:ok, audio} <- Audio.parse(Map.get(config, "audio", %{})),
         {:ok, duration} <-
           Validate.optional_int(config, "duration", 1..@max_duration, "synthetic") do
      {:ok, %{video: video, audio: audio, duration: duration}}
    end
  end

  @spec summary(t()) :: map()
  def summary(config), do: put_in(config, [:video, :fps], Video.encode_fps(config.video.fps))
end
