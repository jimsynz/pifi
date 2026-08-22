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

  `favourite?` is `nil` for a source that holds no favourites. A user interface
  shows the control only for `true` and for `false`, so it needs no knowledge of
  which source it shows.
  """
  @type track :: %{
          ref: ref(),
          title: String.t(),
          subtitle: String.t() | nil,
          artwork: String.t() | nil,
          duration_ms: pos_integer() | nil,
          favourite?: boolean() | nil
        }

  @type entry :: {:container, container()} | {:track, track()}

  @typedoc """
  One page of entries.

  `cursor` names the next page, and a `nil` cursor means that this is the last one.
  """
  @type page :: %{entries: [entry()], cursor: term() | nil}

  @typedoc """
  Everything that the player needs to play a track.

  Three facts decide the pipeline, and they are separate because they vary
  separately.

  - `transport` is how the bytes arrive. `:http` is one continuous answer, and
    `:hls` is a playlist of segments that the player reads again and again.
  - `container` is what holds the audio. `:mpeg_ts` needs a demultiplexer, `:ogg`
    names a container that the decoder reads itself, and `:none` gives the audio as
    it is.
  - `format` is the codec.

  Two kinds of station show why. Of the 44 New Zealand HLS stations, 14 give AAC
  with no container and 8 give MP3 inside MPEG-TS. Of the 6 Ogg stations, 3 hold
  Vorbis and 3 hold FLAC, and the service reports the codec `OGG` for every one of
  them. One field cannot say any of that.

  `live?` is true for a stream with no end, such as a radio station.
  """
  @type playable :: %{
          uri: String.t(),
          headers: [{String.t(), String.t()}],
          transport: :http | :hls,
          container: :none | :mpeg_ts | :ogg,
          format: :mp3 | :aac | :flac | :vorbis | :opus | :speex | :unknown,
          live?: boolean()
        }

  @doc "The name of this source, for a person to read."
  @callback title() :: String.t()

  @doc """
  The icon of this source.

  A source names its own icon, and each user interface draws that name in its own
  way. The web interface draws a heroicon, and the device screen draws a Vivid
  shape. Neither one holds a list of the sources.

  The interfaces draw `:radio`, `:library`, `:podcast` and `:cloud` today. Any
  other name gives the default icon, so a new source works before an interface
  learns its icon.
  """
  @callback icon() :: atom()

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

  @doc """
  Give a `ref` a name that a caller can store.

  The player keeps the last station in the settings, and a setting holds a string.
  A source therefore names its own `ref`, and it reads that name back with
  `ref_from_string/1`.

  The player could store the term itself instead. It does not, for three reasons.
  A name is readable when a person looks in the database. Nothing turns stored
  bytes back into a term, so a changed row cannot make an atom or run a function.
  A source that changes the shape of its `ref` also keeps the old name working,
  and a stored term gives it no way to do that.

  A source gives `{:error, :cannot_name}` for a `ref` that it does not name. The
  player needs the tracks, and a source needs no more than that.
  """
  @callback ref_to_string(ref()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Read a `ref` back from its name.

  The name comes from `ref_to_string/1` of the same source. A source gives an
  error for a name that it does not know, so an old setting cannot break a start.
  """
  @callback ref_from_string(String.t()) :: {:ok, ref()} | {:error, term()}

  @doc """
  Make one entry a favourite, or remove that mark.

  A source with no favourites gives `{:error, :not_supported}`, in the same way
  that `search/2` does. Each service holds its own idea of this mark, and a user
  interface therefore never reads or writes the mark itself.
  """
  @callback favourite(ref(), boolean()) :: :ok | {:error, term()}

  @doc """
  Every source that this firmware holds.

  Internet radio is the only one today. A new source joins this list, and the web
  interface and the device interface then show it without a change. A test sets
  `:sources` to give a source of its own.
  """
  @spec all() :: [module()]
  def all, do: Application.get_env(:my_hi_fi, :sources, [MyHiFi.Source.InternetRadio])

  @doc """
  Read a source back from its name.

  The name comes from a request, so this compares it with the name of each source
  of `all/0`. It turns no text into an atom, and an unknown name gives an error.
  """
  @spec from_slug(String.t()) :: {:ok, module()} | {:error, :not_a_source}
  def from_slug(name) do
    case Enum.find(all(), &(slug(&1) == name)) do
      nil -> {:error, :not_a_source}
      module -> {:ok, module}
    end
  end

  @doc """
  The name of a source in an address.

  The web interface holds one address for each source, and a person can keep that
  address. The name comes from the module, so a new source needs no registration.

      iex> MyHiFi.Source.slug(MyHiFi.Source.InternetRadio)
      "internet-radio"
  """
  @spec slug(module()) :: String.t()
  def slug(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.replace("_", "-")
  end
end
