defmodule PiFi.Test.PlainSource do
  @moduledoc """
  A source that holds nothing for a person to change.

  `settings/0` and the three callbacks beside it are optional, so a source that
  needs no configuration implements none of them. The settings page must then show
  the control that puts the source in use, and nothing else.

  This source browses nothing. A test that needs a tree uses one of its own.
  """

  @behaviour PiFi.Source

  @impl PiFi.Source
  def title, do: "Plain source"

  @impl PiFi.Source
  def icon, do: :library

  @impl PiFi.Source
  def capabilities, do: []

  @impl PiFi.Source
  def roots, do: []

  @impl PiFi.Source
  def kinds, do: [track: "Tracks"]

  @impl PiFi.Source
  def resolve(item), do: {:error, {:not_a_track, item.id}}
end
