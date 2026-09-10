defmodule MyHiFi.Artwork.Accent do
  @moduledoc """
  The colour that one picture gives to the interface.

  The device screen and the web page both draw a colour that comes from the artwork
  of the track. **This module owns that rule, and it owns it one time.** The page
  held its own copy in JavaScript, which read the same thumbnail in a canvas. Two
  copies of one rule drift, and a change of a clamp then left the screen and the page
  disagreeing about the same track.

  ## The rule

  The work happens in OKLab, because a step of the same size is a step of the same
  size to a person there, and neither RGB nor HSL gives that. Each pixel of a small
  grid becomes a lightness, an `a` and a `b`. A pixel that is nearly black or nearly
  white says nothing about the colour of a picture, so it goes. The rest fall into 24
  buckets of hue, and each one carries the square of its chroma as its weight, so a
  strong colour of a few pixels beats a weak colour of many.

  The heaviest bucket gives the answer, as the weighted mean of what fell in it.
  **A picture with a little colour therefore gives that colour**, even when most
  of it is grey or dark: the most that a picture has is what a person sees in it.

  **The answer is then clamped, and that is what makes it usable.** A colour as found
  is often too dark or too strong to read on the slate of the faceplate and of the
  screen. The lightness stays between 0.72 and 0.84, and the chroma between 0.08 and
  0.19, so every picture gives a colour that a person can read text against.

  **A picture of greys gives no colour at all**, and a caller then keeps the colour
  that it has. A logo of one grey is common, so this is not a rare path.

  The chroma of the winning bucket is what says which of the two a picture is, and not
  the weight of it. The weight is a sum, so it grows with the number of pixels that a
  grid has and with how much of the picture is colour. Three covers of this device
  measured on 2026-09-01: a red logo reached a chroma of 0.213, a dark cover of a
  green face and a red shirt reached 0.057, and a cover in black and white reached
  0.000. The floor at 0.02 therefore takes the second one and refuses the third, and
  it says the same thing for a grid of any size.

  The floor is not zero, because a picture in black and white that a JPEG carries
  carries faint colour at each edge, and a rule of "more than nothing" would take
  that.

  `MyHiFi.Artwork.Thumbnail.digest/0` reads the code of this module, so a change of a
  clamp here writes a new thumbnail and a new colour for every picture that a device
  keeps.

  ## What each caller needs

  The page names a colour in `oklch()`, so `to_css/1` gives that and the browser turns
  it into pixels. The screen has no such reader, so `to_rgb/1` does the work that
  the browser does: OKLab back to sRGB.
  """

  @sample 32
  @buckets 24
  @min_chroma 0.02
  @lightness {0.72, 0.84}
  @chroma {0.08, 0.19}

  @typedoc "One colour, as a person sees it."
  @type t :: %{lightness: float(), chroma: float(), hue: float()}

  @doc "The width and the height of the grid that `from_pixels/1` reads."
  @spec sample() :: pos_integer()
  def sample, do: @sample

  @doc """
  The colour of a grid of pixels, or `nil` for a picture with no colour.

  The grid carries three bytes for each pixel, in the order red, green and blue. A
  picture of one band gives `nil`, because a grey picture has no hue.
  """
  @spec from_pixels(binary()) :: t() | nil
  def from_pixels(pixels) when is_binary(pixels) and byte_size(pixels) > 0 do
    if rem(byte_size(pixels), 3) == 0 do
      pixels |> weigh() |> heaviest() |> mean()
    end
  end

  def from_pixels(_pixels), do: nil

  @doc """
  The colour of a grid that `vipsthumbnail` wrote as a PPM file.

  **A PPM says in its own header how many bands it holds**: `P6` is three, and `P5`
  is one. A grey picture therefore gives `nil` here and needs no flag on the command
  and no second call to ask for the size. A raw file says nothing, and a reader of one
  cannot tell one band from three.
  """
  @spec from_ppm(binary()) :: t() | nil
  def from_ppm("P6" <> rest), do: rest |> after_fields(3) |> from_pixels()
  def from_ppm(_binary), do: nil

  @doc "The colour as a page names it."
  @spec to_css(t()) :: String.t()
  def to_css(%{lightness: lightness, chroma: chroma, hue: hue}) do
    "oklch(#{round_to(lightness, 3)} #{round_to(chroma, 3)} #{round_to(hue, 1)})"
  end

  @doc """
  The colour as the screen holds it, which is one byte for each of red, green and
  blue.
  """
  @spec to_rgb(t()) :: {0..255, 0..255, 0..255}
  def to_rgb(%{lightness: lightness, chroma: chroma, hue: hue}) do
    radians = hue * :math.pi() / 180
    a = chroma * :math.cos(radians)
    b = chroma * :math.sin(radians)

    long = cube(lightness + 0.3963377774 * a + 0.2158037573 * b)
    medium = cube(lightness - 0.1055613458 * a - 0.0638541728 * b)
    short = cube(lightness - 0.0894841775 * a - 1.2914855480 * b)

    {
      byte(4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short),
      byte(-1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short),
      byte(-0.0041960863 * long - 0.7034186147 * medium + 1.7076147010 * short)
    }
  end

  # The header holds the width, the height and the largest value that a band takes,
  # and one space or newline then holds the data apart from them. A comment may sit
  # between any two of them.
  defp after_fields(<<_whitespace, data::binary>>, 0), do: data

  defp after_fields(<<char, rest::binary>>, count) when char in ~c" \t\r\n",
    do: after_fields(rest, count)

  defp after_fields(<<?#, rest::binary>>, count) do
    rest
    |> :binary.split("\n")
    |> List.last()
    |> after_fields(count)
  end

  defp after_fields(<<char, rest::binary>>, count) when char in ?0..?9 do
    after_fields(rest, count, :digits)
  end

  defp after_fields(_binary, _count), do: ""

  defp after_fields(<<char, rest::binary>>, count, :digits) when char in ?0..?9 do
    after_fields(rest, count, :digits)
  end

  defp after_fields(binary, count, :digits), do: after_fields(binary, count - 1)

  defp weigh(pixels) do
    for <<red, green, blue <- pixels>>, reduce: %{} do
      buckets -> add(buckets, oklab(red, green, blue))
    end
  end

  # A pixel that is nearly black or nearly white says nothing about the colour of a
  # picture, and a cover holds many of both.
  defp add(buckets, {lightness, _a, _b}) when lightness < 0.12 or lightness > 0.95, do: buckets

  defp add(buckets, {lightness, a, b}) do
    weight = a * a + b * b

    Map.update(
      buckets,
      bucket(a, b),
      {weight, a * weight, b * weight, lightness * weight},
      fn {sum, a_sum, b_sum, lightness_sum} ->
        {sum + weight, a_sum + a * weight, b_sum + b * weight, lightness_sum + lightness * weight}
      end
    )
  end

  # The weight is the square of the chroma, so a strong colour of a few pixels beats a
  # weak colour of many. A picture of greys therefore reaches no weight at all.
  defp heaviest(buckets) when map_size(buckets) == 0, do: nil

  defp heaviest(buckets) do
    {_bucket, heaviest} = Enum.max_by(buckets, fn {_bucket, {sum, _, _, _}} -> sum end)

    heaviest
  end

  defp mean(nil), do: nil

  defp mean({sum, a_sum, b_sum, lightness_sum}) do
    a = a_sum / sum
    b = b_sum / sum

    colour(:math.sqrt(a * a + b * b), a, b, lightness_sum / sum)
  end

  # A picture that holds no colour reaches no chroma, and the clamp below would then
  # make a colour out of nothing.
  defp colour(chroma, _a, _b, _lightness) when chroma < @min_chroma, do: nil

  defp colour(chroma, a, b, lightness) do
    %{
      lightness: clamp(@lightness, lightness),
      chroma: clamp(@chroma, chroma),
      hue: hue(a, b)
    }
  end

  defp bucket(a, b), do: floor(hue(a, b) / (360 / @buckets))

  defp hue(a, b) do
    degrees = :math.atan2(b, a) * 180 / :math.pi()

    degrees |> :math.fmod(360) |> Kernel.+(360) |> :math.fmod(360)
  end

  defp oklab(red, green, blue) do
    r = linear(red)
    g = linear(green)
    b = linear(blue)

    long = :math.pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1 / 3)
    medium = :math.pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1 / 3)
    short = :math.pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1 / 3)

    {
      0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short,
      1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short,
      0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
    }
  end

  defp linear(value) do
    channel = value / 255

    if channel <= 0.04045 do
      channel / 12.92
    else
      :math.pow((channel + 0.055) / 1.055, 2.4)
    end
  end

  defp cube(value), do: value * value * value

  defp byte(linear) do
    channel =
      if linear <= 0.0031308 do
        12.92 * linear
      else
        1.055 * :math.pow(Kernel.max(linear, 0.0), 1 / 2.4) - 0.055
      end

    channel |> Kernel.*(255) |> round() |> Kernel.max(0) |> Kernel.min(255)
  end

  defp clamp({low, high}, value), do: value |> Kernel.max(low) |> Kernel.min(high)

  defp round_to(value, places) do
    factor = :math.pow(10, places)

    (value * factor) |> round() |> Kernel./(factor)
  end
end
