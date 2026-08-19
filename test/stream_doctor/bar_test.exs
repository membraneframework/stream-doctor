defmodule StreamDoctor.BarTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.Bar

  @width 640
  @height 360

  defp grey_frame() do
    y = :binary.copy(<<128>>, @width * @height)
    chroma = :binary.copy(<<128>>, div(@width * @height, 4))
    y <> chroma <> chroma
  end

  test "draw/decode round-trip" do
    geometry = Bar.geometry(@width, @height)

    for frame_number <- [0, 1, 42, 12_345, Bar.max_frame() - 1, Bar.max_frame() + 7] do
      payload = Bar.draw(grey_frame(), geometry, frame_number)
      assert byte_size(payload) == byte_size(grey_frame())
      assert {:ok, rem(frame_number, Bar.max_frame())} == Bar.decode(payload, geometry)
    end
  end

  test "decode reports missing bar" do
    geometry = Bar.geometry(@width, @height)
    assert {:error, :markers_not_found} == Bar.decode(grey_frame(), geometry)
  end

  test "decode survives mild compression noise" do
    geometry = Bar.geometry(@width, @height)
    payload = Bar.draw(grey_frame(), geometry, 1234)

    noisy =
      payload
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {value, index} ->
        min(255, max(0, value + rem(index * 31, 21) - 10))
      end)
      |> :binary.list_to_bin()

    assert {:ok, 1234} == Bar.decode(noisy, geometry)
  end
end
