defmodule MyHiFi.Artwork.Thumbnail do
  @moduledoc """
  A small version of artwork for the device screen.

  The screen is 320 by 240 pixels. A podcast cover is 3000 by 3000, which is 1.2 MB
  and too large to send to Emerge. This variant makes a JPEG of 320 pixels wide,
  preserving the aspect ratio.

  `vipsthumbnail` does the work. It shrinks on load, so the full image never exists
  in memory. The output is JPEG at 85% quality, because the screen is 18-bit colour
  and the loss is invisible.

  **`>` in the size makes it shrink a picture and never grow one.** A size of `320x`
  alone grows a small picture to 320 pixels, and a station logo is usually smaller
  than the screen. One logo of 180 by 180 pixels and 3735 bytes became 320 by 320
  pixels and 10285 bytes on the device, which is more bytes and no more detail.

  WebP and GIF do not get thumbnails. libvips in this firmware reads WebP and GIF
  but writes neither, so those formats stay as they are.
  """

  @behaviour AshStorage.Variant

  @width 320
  @size "#{@width}x>"
  @quality 85

  @doc """
  What the settings of this variant are, in 16 characters.

  Each thumbnail row holds this, and `MyHiFi.Artwork.generate_thumbnail/1` compares
  it. A thumbnail that an older build wrote therefore gives way to a new one, and a
  change here reaches every picture that the device holds.

  **The digest of `AshStorage` cannot do this work.** `AshStorage.VariantDefinition`
  hashes the module and the options that a resource declares, and this variant
  declares no option, so the width and the quality never move it.
  """
  @spec digest() :: String.t()
  def digest do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({__MODULE__, @size, @quality}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @impl true
  def accept?("image/jpeg"), do: true
  def accept?("image/png"), do: true
  def accept?(_content_type), do: false

  @impl true
  def transform(source_path, dest_path, _opts) do
    args = [
      source_path,
      "--size",
      @size,
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
