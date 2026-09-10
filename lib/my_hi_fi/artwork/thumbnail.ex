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

  ## The colour

  The thumbnail carries the accent colour of the picture, in its metadata. The work
  happens here because `vipsthumbnail` runs here: a second run gives a grid of 32 by
  32 pixels, and `MyHiFi.Artwork.Accent` reads it.

  **The grid is a PPM file and not a raw one.** A PPM carries a header that says how
  many bands it carries, so a thumbnail of one band reads as the grey that it is. A
  raw file carries bytes alone, so a grid of grey would read as a grid of colour, and a
  picture of greys would give a colour that no person can see in it. `vipsthumbnail`
  of this version takes no option that forces three bands, so the format is what
  answers the question.
  """

  @behaviour AshStorage.Variant

  alias MyHiFi.Artwork.Accent

  # Sobelow reads `@sobelow_skip` from the source. This registration stops the
  # compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @width 320
  @size "#{@width}x>"
  @quality 85

  @doc """
  What decides the thumbnail and its colour, in 16 characters.

  Each thumbnail row carries this, and `MyHiFi.Artwork.generate_thumbnail/1` compares
  it. A thumbnail that an older build wrote therefore gives way to a new one, and a
  change here reaches every picture that the device keeps.

  **It reads the code of this module and of `MyHiFi.Artwork.Accent`, and not their
  settings alone.** A build once changed how the colour is read and left every
  constant as it was. The digest did not move, each device kept the thumbnail that it
  held, and the new build therefore showed nothing new. The BEAM keeps a hash of the
  code of each module, so this reads that and no person has to remember.

  **The digest of `AshStorage` cannot do this work.** `AshStorage.VariantDefinition`
  hashes the module and the options that a resource declares, and this variant
  declares no option, so nothing here would ever move it.
  """
  @spec digest() :: String.t()
  def digest do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({code(__MODULE__), code(Accent)}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp code(module) do
    Code.ensure_loaded(module)

    module.module_info(:md5)
  end

  @impl true
  def accept?("image/jpeg"), do: true
  def accept?("image/png"), do: true
  def accept?(_content_type), do: false

  @impl true
  def transform(source_path, dest_path, _opts) do
    with {:ok, _output} <- shrink(source_path, dest_path <> "[Q=#{@quality}]", @size) do
      {:ok, %{content_type: "image/jpeg", accent: accent(dest_path)}}
    end
  end

  # The colour comes from the thumbnail and not from the picture, and the web page
  # reads that same thumbnail, so the screen and the page answer from one set of bytes.
  # See `MyHiFi.Artwork.Accent`.
  #
  # **A picture that gives no colour is normal, and so is a libvips that cannot write
  # this grid.** A thumbnail is worth more than a colour, so neither one fails it.
  @sobelow_skip ["Traversal.FileModule"]
  defp accent(thumbnail_path) do
    grid = Path.join(System.tmp_dir!(), "accent_#{:erlang.unique_integer([:positive])}.ppm")
    size = Accent.sample()

    try do
      with {:ok, _output} <- shrink(thumbnail_path, grid, "#{size}x#{size}"),
           {:ok, ppm} <- File.read(grid) do
        Accent.from_ppm(ppm)
      else
        _other -> nil
      end
    after
      File.rm(grid)
    end
  end

  defp shrink(source_path, dest_path, size) do
    args = [source_path, "--size", size, "-o", dest_path]

    try do
      case System.cmd("vipsthumbnail", args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, exit_code} -> {:error, {:vipsthumbnail_failed, exit_code, output}}
      end
    rescue
      ErlangError ->
        {:error, :vipsthumbnail_not_found}
    end
  end
end
