defmodule MyHiFi.Screen.Row do
  @moduledoc """
  A row that puts one thing at each end, drawn for a screen that Emerge renders.

  The time of a track and the time that is left, the word `VOLUME` and the level, the
  network and the battery: each screen of this device draws several rows of that
  shape. See `MyHiFi.Screen`.

  **A child that fills the middle, and not `Emerge.UI.align_right/0` on the last one.**
  That attribute pins one child to the right of a row, and every child after it then
  flows back beside the first. A child that fills the space instead pushes all the
  rest to the far end, which is where a person looks for them.
  """

  use Emerge.UI

  @doc """
  Draw one row, with the first list at one end and the second at the other.

  ## Options

  - `:spacing` - the space between two things at the same end, in pixels. None by
    default.
  - `:padding` - the space around the row, as `{across, down}` in pixels. None by
    default.
  """
  @spec ends([Emerge.tree()], [Emerge.tree()], keyword()) :: Emerge.tree()
  def ends(left, right, options \\ []) do
    row(attributes(options), left ++ [gap()] ++ right)
  end

  @doc """
  A child that takes every pixel that the rest of a row leaves.
  """
  @spec gap() :: Emerge.tree()
  def gap, do: el([width(fill())], none())

  defp attributes(options) do
    [width(fill())]
    |> put_spacing(Keyword.get(options, :spacing))
    |> put_padding(Keyword.get(options, :padding))
  end

  defp put_spacing(attributes, nil), do: attributes
  defp put_spacing(attributes, pixels), do: attributes ++ [spacing(pixels)]

  defp put_padding(attributes, nil), do: attributes
  defp put_padding(attributes, {across, down}), do: attributes ++ [padding_xy(across, down)]
end
