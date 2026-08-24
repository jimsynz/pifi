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
  def root, do: :root

  @impl MyHiFi.Source
  def browse(_ref, _options \\ []), do: {:ok, %{entries: [], cursor: nil}}

  @impl MyHiFi.Source
  def search(_query, _options \\ []), do: {:error, :not_supported}

  @impl MyHiFi.Source
  def track(ref), do: {:error, {:not_a_track, ref}}

  @impl MyHiFi.Source
  def resolve(ref), do: {:error, {:not_a_track, ref}}

  @impl MyHiFi.Source
  def next(_ref), do: {:error, :not_supported}

  @impl MyHiFi.Source
  def previous(_ref), do: {:error, :not_supported}

  @impl MyHiFi.Source
  def ref_to_string(_ref), do: {:error, :cannot_name}

  @impl MyHiFi.Source
  def ref_from_string(_name), do: {:error, :not_a_name}

  @impl MyHiFi.Source
  def favourite(_ref, _true?), do: {:error, :not_supported}

  @impl MyHiFi.Source
  def store_position(_ref, _place), do: :ok

  @impl MyHiFi.Source
  def finished(_ref), do: :ok
end
