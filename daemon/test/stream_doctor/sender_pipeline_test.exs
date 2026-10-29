defmodule StreamDoctor.SenderPipelineTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Testing
  alias StreamDoctor.OptionsParser.Publisher
  alias StreamDoctor.SenderPipeline.{Ingest, Processing}

  defp start(settings) do
    {:ok, {:synthetic, config}} = Publisher.parse(%{"synthetic" => settings})

    spec =
      config
      |> Ingest.Synthetic.tracks()
      |> Processing.tracks(config)
      |> Enum.map(fn {kind, builder} -> child(builder, {:sink, kind}, Testing.Sink) end)

    pid = Testing.Pipeline.start_link_supervised!(spec: spec)
    on_exit(fn -> Testing.Pipeline.terminate(pid) end)
    pid
  end

  defp video_encoder(settings) do
    {:ok, {:synthetic, config}} = Publisher.parse(%{"synthetic" => %{"video" => settings}})

    %{video: %Membrane.ChildrenSpec.Builder{children: children}} =
      config |> Ingest.Synthetic.tracks() |> Processing.tracks(config)

    Enum.find_value(children, fn {name, struct, _opts} -> name == :encoder && struct end)
  end

  test "video settings reach the encoder, with the bitrate rounded to whole kbit/s" do
    assert %{crf: 18, gop_size: 15, ffmpeg_params: %{"x264-params" => "bitrate=2"}} =
             video_encoder(%{"crf" => 18, "gop_size" => 15, "bitrate" => 1_500})

    assert %{ffmpeg_params: %{"x264-params" => "bitrate=400"}} =
             video_encoder(%{"bitrate" => 400_000})

    assert %{ffmpeg_params: params} = video_encoder(%{})
    assert params == %{}
  end

  test "a synthetic source reaches the sink as encoded video and audio" do
    pid = start(%{"video" => %{"width" => 320, "height" => 240}})

    assert_sink_stream_format(pid, {:sink, :video}, %Membrane.H264{}, 15_000)
    assert_sink_stream_format(pid, {:sink, :audio}, %Membrane.AAC{}, 15_000)
  end

  test "a duration ends both tracks" do
    pid = start(%{"duration" => 1, "video" => %{"width" => 320, "height" => 240}})

    assert_end_of_stream(pid, {:sink, :video}, :input, 15_000)
    assert_end_of_stream(pid, {:sink, :audio}, :input, 15_000)
  end
end
