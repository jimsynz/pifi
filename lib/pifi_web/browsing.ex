defmodule PiFiWeb.Browsing do
  @moduledoc """
  Where the browser opens, and where it was last.

  **Navigation and selection are two different facts, and one setting used to hold
  both.** The source that the device is on is what the player is playing — the top row
  of the faceplate reads `PiFi.Playback.state!()` and nothing stores it. The source that
  a person was last reading about is a fact about this interface alone, so it lives
  here, beside the pages that write it, and not in `PiFi.Source`.

  That is also why the device screen appears nowhere in this module. `PiFi.DeviceUi`
  holds its own navigation state for the same reason: a screen and a browser are two
  people looking at one device, and neither one moves the other.

  ## What moved, and what it cost

  `PiFi.Source.choose/1` was named for a switch and used as a bookmark. The pages wrote
  it on every navigation, and `PiFi.Plex.Companion.Router` wrote it when a controller
  started playing — to make a person who walked to the device find it where the music
  was, which is a fact about the device that it had nowhere else to put. So a cast
  moved the browser's bookmark, and reading about a station moved the device's switch.

  Nothing but the pages writes this now, and a cast moves nothing: the row of the
  faceplate reads the player, which knew all along.
  """

  alias PiFi.Playback
  alias PiFi.Settings
  alias PiFi.Source

  require Logger

  @key "browse.source"

  @doc """
  The settings key that remembers the last source a person read.

      iex> PiFiWeb.Browsing.key()
      "browse.source"
  """
  @spec key() :: String.t()
  def key, do: @key

  @doc """
  The source that `/browse` opens at.

  **What the device is playing comes first**, because a person who casts a record and
  then opens the browser is looking for that record. A source that browses nothing is
  skipped: `PiFi.Source.AirPlay` and `PiFi.Source.Spotify` answer `{:error, module}`
  from `c:PiFi.Source.roots/0`, and landing a person on a page that explains it browses
  nothing is worse than landing them where they were.

  Then where they were, and then the first source in use. It returns `nil` for a device
  with no source in use at all.
  """
  @spec landing() :: module() | nil
  def landing, do: playing() || last() || List.first(Source.enabled())

  @doc """
  The source a person was last reading about, if it is still one they can read.
  """
  @spec last() :: module() | nil
  def last do
    with {:ok, %{value: slug}} <- Settings.fetch(@key),
         {:ok, module} <- Source.from_slug(slug),
         true <- Source.enabled?(module) do
      module
    else
      _other -> nil
    end
  end

  @doc """
  Note that a person is reading about one source.

  **It raises nothing.** No person asked for this write: it is what the browser
  remembers while they look at a list. A write that fails must leave the bookmark where
  it was and let them keep reading.
  """
  @spec visited(module()) :: :ok
  def visited(module) do
    slug = Source.slug(module)

    if stored() != slug do
      case Settings.put(@key, slug) do
        {:ok, _setting} ->
          :ok

        {:error, reason} ->
          Logger.warning("The browser did not remember the source: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp playing do
    case Playback.state!() do
      %{source: module} when not is_nil(module) -> if readable?(module), do: module
      _other -> nil
    end
  end

  # A source browses nothing when it says so, and one that a person took out of use is
  # not one to open either.
  defp readable?(module) do
    Source.enabled?(module) and not match?({:error, _reason}, module.roots())
  end

  defp stored do
    case Settings.fetch(@key) do
      {:ok, %{value: slug}} -> slug
      {:error, _reason} -> nil
    end
  end
end
