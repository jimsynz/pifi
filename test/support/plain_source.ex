defmodule MyHiFi.Test.PlainSource do
  @moduledoc """
  A source that holds nothing for a person to change.

  `settings/0` and the three callbacks beside it are optional, so a source that
  needs no configuration implements none of them. The settings page must then show
  the control that puts the source in use, and nothing else.

  This source browses nothing. A test that needs a tree uses one of its own.
  """

  @behaviour MyHiFi.Source

  @impl MyHiFi.Source
  def title, do: "Plain source"

  @impl MyHiFi.Source
  def icon, do: :library

  @impl MyHiFi.Source
  def capabilities, do: []

  @impl MyHiFi.Source
  def roots, do: []

  @impl MyHiFi.Source
  def kinds, do: [track: "Tracks"]

  @impl MyHiFi.Source
  def resolve(item), do: {:error, {:not_a_track, item.id}}
end
