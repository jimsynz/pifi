defmodule MyHiFi.Artwork.Thumbnail do
  @moduledoc """
  A small version of artwork for the device screen.

  The screen is 320 by 240 pixels. A podcast cover is 3000 by 3000, which is 1.2 MB
  and too large to send to Emerge. This variant makes a JPEG of 320 pixels wide,
  preserving the aspect ratio.

  `vipsthumbnail` does the work. It shrinks on load, so the full image never exists
  in memory. The output is JPEG at 85% quality, because the screen is 18-bit colour
  and the loss is invisible.

  WebP and GIF do not get thumbnails. libvips in this firmware reads WebP and GIF
  but writes neither, so those formats stay as they are.
  """

  @behaviour AshStorage.Variant

  @width 320
  @quality 85

  @impl true
  def accept?("image/jpeg"), do: true
  def accept?("image/png"), do: true
  def accept?(_content_type), do: false

  @impl true
  def transform(source_path, dest_path, _opts) do
    args = [
      source_path,
      "--size",
      "#{@width}x",
      "-o",
      dest_path <> "[Q=#{@quality}]"
    ]

    try do
      case System.cmd("vipsthumbnail", args, stderr_to_stdout: true) do
        {_output, 0} ->
          {:ok, %{content_type: "image/jpeg"}}

        {output, exit_code} ->
          {:error, {:vipsthumbnail_failed, exit_code, output}}
      end
    rescue
      ErlangError ->
        {:error, :vipsthumbnail_not_found}
    end
  end
end
