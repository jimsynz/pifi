defmodule PiFi.AirPlay.NowPlaying do
  @moduledoc """
  Reads what a telephone says is playing, out of the plist it posts to `/command`.

  **Bit 50 of `PiFi.AirPlay.Advertisement` is why the metadata arrives this way.** With
  it set a sender posts a binary plist here and sends nothing at all through the
  AirPlay 1 path — no `SET_PARAMETER` text, no progress, no artwork. See that module.

  ## The shape came off a real telephone

  There is no specification for this, and the one receiver project that was asked about
  it gave an answer that was invented. So the shape below is what a telephone at
  192.168.5.50 actually sent on 2026-10-08, with a podcast playing:

      %{
        "type" => "updateMRNowPlayingInfo",
        "params" => %{
          "mergePolicy" => "replace",
          "type" => "npi-text",
          "params" => %{
            "kMRMediaRemoteNowPlayingInfoTitle" => "Gear: Chapter 6 (S7 E7)",
            "kMRMediaRemoteNowPlayingInfoArtist" => "Articles of Interest",
            "kMRMediaRemoteNowPlayingInfoAlbum" => "26 November 2025",
            "kMRMediaRemoteNowPlayingInfoArtworkData" => <<...>>,
            "kMRMediaRemoteNowPlayingInfoArtworkMIMEType" => "image/jpeg",
            "kMRMediaRemoteNowPlayingInfoDuration" => 3076.752,
            "kMRMediaRemoteNowPlayingInfoElapsedTime" => 49.955699958,
            ...
          }
        }
      }

  **The artwork is in the plist and not behind an address.** 66 KB of JPEG arrived
  inside that message, so nothing here fetches anything and the picture is ready the
  moment the message is read.

  A sender posts other things to the same route — `updateMRSupportedCommands` is the
  list of controls it will accept — and each one that is not the now-playing message is
  ignored rather than guessed at.

  ## An empty message is a sender clearing what it said

  The first `npi-text` of a session carries an empty `params`, before the telephone has
  decided what it is playing. **That is not a track with no title**, so it is ignored:
  a message that named nothing would otherwise wipe the title of the track that is
  playing and put an empty line in front of a person.
  """

  @prefix "kMRMediaRemoteNowPlayingInfo"

  @typedoc """
  What a telephone says is playing.

  Every field is optional, because a sender sends what it has: a podcast carries a
  show and an episode, and a track that nobody tagged carries a title alone.
  """
  @type t :: %{
          title: String.t() | nil,
          artist: String.t() | nil,
          album: String.t() | nil,
          artwork: binary() | nil,
          artwork_type: String.t() | nil
        }

  @doc """
  What one `/command` body says is playing, or `:ignore` for one that says nothing.

      iex> PiFi.AirPlay.NowPlaying.read(%{
      ...>   "type" => "updateMRNowPlayingInfo",
      ...>   "params" => %{
      ...>     "type" => "npi-text",
      ...>     "params" => %{"kMRMediaRemoteNowPlayingInfoTitle" => "A Song"}
      ...>   }
      ...> })
      {:ok, %{title: "A Song", artist: nil, album: nil, artwork: nil, artwork_type: nil}}

  A message of another kind is not one this firmware reads.

      iex> PiFi.AirPlay.NowPlaying.read(%{"type" => "updateMRSupportedCommands"})
      :ignore

  Nor is one that names nothing.

      iex> PiFi.AirPlay.NowPlaying.read(%{
      ...>   "type" => "updateMRNowPlayingInfo",
      ...>   "params" => %{"type" => "npi-text", "params" => %{}}
      ...> })
      :ignore
  """
  @spec read(term()) :: {:ok, t()} | :ignore
  def read(%{"type" => "updateMRNowPlayingInfo", "params" => %{"params" => fields}})
      when is_map(fields) and map_size(fields) > 0 do
    playing = %{
      title: text(fields, "Title"),
      artist: text(fields, "Artist"),
      album: text(fields, "Album"),
      artwork: picture(fields),
      artwork_type: text(fields, "ArtworkMIMEType")
    }

    if named?(playing), do: {:ok, playing}, else: :ignore
  end

  def read(_other), do: :ignore

  @doc """
  The one line a person reads, from what a sender named.

  **It is the shape `PiFi.Spotify.Monitor` already uses**, because the two are the same
  thing to a person: a telephone deciding what plays, and one line of text under the
  name of the device.

      iex> PiFi.AirPlay.NowPlaying.line(%{title: "A Song", artist: "Someone"})
      "A Song · Someone"

      iex> PiFi.AirPlay.NowPlaying.line(%{title: "A Song", artist: nil})
      "A Song"

  A sender that named an artist and no title gives the artist, because a line with a
  name in it reads better than no line at all.

      iex> PiFi.AirPlay.NowPlaying.line(%{title: nil, artist: "Someone"})
      "Someone"
  """
  @spec line(t()) :: String.t() | nil
  def line(%{title: title, artist: artist}) when is_binary(title) and is_binary(artist),
    do: title <> " · " <> artist

  def line(%{title: title}) when is_binary(title), do: title
  def line(%{artist: artist}) when is_binary(artist), do: artist
  def line(_playing), do: nil

  # A sender sends a message for each thing that changes, so one that names no words and
  # no picture is one that changed something this firmware does not show — the elapsed
  # time, usually.
  defp named?(playing) do
    playing.artwork != nil or line(playing) != nil
  end

  defp text(fields, name) do
    case Map.get(fields, @prefix <> name) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp picture(fields) do
    case Map.get(fields, @prefix <> "ArtworkData") do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end
end
