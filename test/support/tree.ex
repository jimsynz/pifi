defmodule PiFi.Test.Tree do
  @moduledoc """
  Reads an Emerge tree, so a test of a screen asks what the screen shows.

  **A test of a layout must not measure pixels.** An earlier suite counted the pixels
  of one colour on one row of the glass, and a change of a margin, of a colour or of a
  border broke a test that cared about none of the three. It also said nothing that a
  person could read: `bar_width(view) == 0` is not "the screen draws no bar".

  A screen returns a tree, so a test reads the tree:

      assert "PLAYING" in Tree.texts(tree)
      assert Tree.shows?(tree, Battery.render(50, false))

  **A test of the drawing itself still reads pixels**, and it should: the test of
  `PiFi.Screen.Battery` draws a battery and measures it, because the shape of a
  battery is the whole of what that module does. This is for a test of a **layout**,
  which asks what is on the screen and not what each pixel of it holds. See
  `PiFi.Test.Drawing` for the other one.

  ## Why the parts carry no name

  `Emerge.UI.key/1` looks like the way to name a part and find it again. It is not.
  Emerge keeps a key for reconciliation, and it raises
  `All siblings must have key when any key is provided`, so one named part means that
  every part beside it needs a name as well. A layout would then carry a list of names
  for the tests and for nothing else, and each new element would break the render
  until a person named it too.

  `shows?/2` needs no name. A screen draws the tree that `PiFi.Screen.Battery` gives
  it, so a test builds the same tree and asks whether the screen holds it.
  """

  alias Emerge.Engine.Element

  @doc """
  Whether the tree draws this part.

  The part is a tree of its own, as `PiFi.Screen.Battery.render/3` and its neighbours
  give one. A screen puts that tree inside its layout without a change, so a test
  builds the part and asks for it.
  """
  @spec shows?(Emerge.tree(), Emerge.tree()) :: boolean()
  def shows?(tree, part), do: Enum.member?(all(tree), part)

  @doc """
  Every word that the tree draws, in the order that it draws them.

  A screen that puts a title in capitals gives the capitals, because that is what a
  person reads.
  """
  @spec texts(Emerge.tree()) :: [String.t()]
  def texts(tree) do
    tree
    |> all()
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map(& &1.attrs.content)
  end

  @doc """
  The first element that the test names, or `nil`.

  A test that wants the width of a bar finds the element that the fill colour names,
  and reads the width from it.
  """
  @spec find_by(Emerge.tree(), (Element.t() -> boolean())) :: Element.t() | nil
  def find_by(tree, predicate), do: tree |> all() |> Enum.find(predicate)

  @doc """
  Every element of the tree, the parent before its children.

  A test that needs something that the rest of this module cannot say reads this.
  """
  @spec all(Emerge.tree()) :: [Element.t()]
  def all(%Element{} = element) do
    [element | Enum.flat_map(element.children ++ element.nearby, &all/1)]
  end

  def all(_other), do: []
end
