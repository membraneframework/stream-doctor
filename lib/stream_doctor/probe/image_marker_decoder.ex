defmodule StreamDoctor.Probe.ImageMarkerDecoder do
  @moduledoc """
  Decodes the frame-number bar (see `StreamDoctor.Probe.Bar`) from a PNG screenshot
  of the played video, e.g. captured from a player's `<video>` element.

  The bar geometry is proportional to the frame size, so a screenshot scaled
  relative to the original stream still decodes - as long as it contains just
  the video area (no letterboxing, and no player controls covering the bar at
  the bottom).
  """

  alias StreamDoctor.Probe.Bar

  @spec decode_frame_number(binary()) ::
          {:ok, non_neg_integer()}
          | {:error,
             :not_a_png | :image_conversion_failed | :markers_not_found | :parity_mismatch}
  def decode_frame_number(png) do
    with {:ok, {width, height}} <- png_dimensions(png),
         {:ok, i420} <- to_i420(png, width, height) do
      Bar.decode(i420, Bar.geometry(width, height))
    end
  end

  # ffmpeg's yuv420p needs even dimensions; odd screenshots get cropped by 1 px
  defp png_dimensions(
         <<137, "PNG\r\n", 26, 10, _length::32, "IHDR", width::32, height::32, _rest::binary>>
       )
       when width > 1 and height > 1,
       do: {:ok, {width - rem(width, 2), height - rem(height, 2)}}

  defp png_dimensions(_other), do: {:error, :not_a_png}

  defp to_i420(png, width, height) do
    path =
      Path.join(
        System.tmp_dir!(),
        "stream_doctor_frame_#{:erlang.unique_integer([:positive])}.png"
      )

    File.write!(path, png)

    try do
      {out, status} =
        System.cmd(
          "ffmpeg",
          ~w(-hide_banner -loglevel error -i #{path} -vf crop=#{width}:#{height}:0:0
             -f rawvideo -pix_fmt yuv420p pipe:1),
          stderr_to_stdout: false
        )

      expected_size = div(width * height * 3, 2)

      case {status, byte_size(out)} do
        {0, ^expected_size} -> {:ok, out}
        _other -> {:error, :image_conversion_failed}
      end
    after
      File.rm(path)
    end
  end
end
