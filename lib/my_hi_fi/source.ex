defmodule MyHiFi.Source do
  @moduledoc """
  Where the music comes from.

  A source shows a tree. A container holds more entries, and a track plays. The
  player and each user interface walk that tree, so neither one holds knowledge of
  any particular service.

  `MyHiFi.Source.InternetRadio` is the only source today. Spotify, Plex,
  Squeezecast and podcasts come later, and each one is a module that implements
  this behaviour and changes nothing else.
  """

  @typedoc """
  Names one entry to a source.

  A source chooses the shape, and no other module reads inside it. A caller passes
  back what a source gave.
  """
  @type ref :: term()

  @typedoc "An entry that holds more entries."
  @type container :: %{ref: ref(), title: String.t(), artwork: String.t() | nil}

  @typedoc """
  An entry that plays.

  `duration_ms` is `nil` for a live stream, because a live stream has no length.
  """
  @type track :: %{
          ref: ref(),
          title: String.t(),
          subtitle: String.t() | nil,
          artwork: String.t() | nil,
          duration_ms: pos_integer() | nil
        }

  @type entry :: {:container, container()} | {:track, track()}

  @typedoc """
  One page of entries.

  `cursor` names the next page, and a `nil` cursor means that this is the last one.
  """
  @type page :: %{entries: [entry()], cursor: term() | nil}

  @typedoc """
  Everything that the player needs to play a track.

  `live?` is true for a stream with no end, such as a radio station.
  """
  @type playable :: %{
          uri: String.t(),
          headers: [{String.t(), String.t()}],
          format: :mp3 | :aac | :flac | :ogg | :hls | :unknown,
          live?: boolean()
        }

  @doc "The name of this source, for a person to read."
  @callback title() :: String.t()

  @doc "The entry at the top of the tree."
  @callback root() :: ref()

  @doc """
  List the entries inside one container.

  Options: `:limit` for the size of a page, and `:cursor` for the page to read.
  """
  @callback browse(ref(), keyword()) :: {:ok, page()} | {:error, term()}

  @doc """
  Find entries that match some text.

  A source with no search gives `{:error, :not_supported}`.
  """
  @callback search(String.t(), keyword()) :: {:ok, page()} | {:error, term()}

  @doc """
  Describe one track.

  The now playing screen needs the title and the artwork of the track that plays,
  and it holds a `ref` and nothing else. Without this a caller would have to walk
  the tree again to find what it already had.
  """
  @callback track(ref()) :: {:ok, track()} | {:error, term()}

  @doc "Turn a track into something that the player can play."
  @callback resolve(ref()) :: {:ok, playable()} | {:error, term()}
end
