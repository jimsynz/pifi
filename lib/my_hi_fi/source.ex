defmodule MyHiFi.Source do
  @moduledoc """
  Where the music comes from.

  A source shows a tree. A container holds more entries, and a track plays. The
  player and each user interface walk that tree, so neither one holds knowledge of
  any particular service.

  `MyHiFi.Source.InternetRadio` and `MyHiFi.Source.Podcasts` are the sources today.
  Spotify, Plex and Squeezecast come later, and each one is a module that
  implements this behaviour and changes nothing else.
  """

  @typedoc """
  What a source holds, beyond the tree that every source holds.

  See `c:capabilities/0`.
  """
  @type capability :: :next | :previous | :search | :skip

  @typedoc """
  One value of a source that a person can change.

  `key` names the field to `put_settings/1`, and it is also the name of the control
  on a page. `type` decides the control: `:text` shows what it holds, and
  `:password` hides it.

  `value` is what the source holds now, and it is nil for a field with
  `write_only?` set. A page then shows an empty control, and it never sends the
  value of that field to a browser.

  `link` names one page that tells a person more, such as where to ask for a key.
  It is separate from `description` because the web interface draws an anchor and
  the device screen can open nothing.

  See `c:settings/0`.
  """
  @type field :: %{
          key: String.t(),
          title: String.t(),
          description: String.t() | nil,
          link: %{href: String.t(), title: String.t()} | nil,
          type: :text | :password,
          value: String.t() | nil,
          write_only?: boolean()
        }

  @typedoc """
  One control of a source that does something, and changes no value.

  `name` names the control to `run_settings_action/1`. `icon` works in the way that
  `c:icon/0` does, and each user interface draws that name itself.

  See `c:settings_actions/0`.
  """
  @type action :: %{
          name: String.t(),
          title: String.t(),
          description: String.t() | nil,
          icon: atom()
        }

  @typedoc """
  Names one entry to a source.

  A source chooses the shape, and no other module reads inside it. A caller passes
  back what a source gave.
  """
  @type ref :: term()

  @typedoc """
  An entry that holds more entries.

  `favourite?` works in the same way as it does on a track, and it is `nil` for a
  container that a person cannot mark.

  Both kinds carry the mark, because each service holds it on a different kind of
  thing. Internet radio marks a station, and a station is a track. Podcasts mark a
  show, and a show is a container. A later source marks an album or a playlist. A
  user interface therefore draws one control for both kinds, and it holds no
  knowledge of which source it shows.
  """
  @type container :: %{
          ref: ref(),
          title: String.t(),
          artwork: String.t() | nil,
          favourite?: boolean() | nil
        }

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
  Where a person stopped in a track.

  `ms` is the time from the start of the track. `bytes` is the byte of the file that
  the reader had reached, and it is nil for a source that reads no file.
  """
  @type place :: %{ms: non_neg_integer(), bytes: non_neg_integer() | nil}

  @typedoc """
  Everything that the player needs to play a track.

  Three facts decide the pipeline, and they are separate because they vary
  separately.

  - `transport` is how the bytes arrive. `:http` is one continuous answer, `:hls` is
    a playlist of segments that the player reads again and again, and `:download`
    is a file that `MyHiFi.Player.Download` writes while the player reads it.
  - `container` is what holds the audio. `:mpeg_ts` needs a demultiplexer, `:ogg`
    names a container that the decoder reads itself, and `:none` gives the audio as
    it is.
  - `format` is the codec.

  Two kinds of station show why. Of the 44 New Zealand HLS stations, 14 give AAC
  with no container and 8 give MP3 inside MPEG-TS. Of the 6 Ogg stations, 3 hold
  Vorbis and 3 hold FLAC, and the service reports the codec `OGG` for every one of
  them. One field cannot say any of that.

  `live?` is true for a stream with no end, such as a radio station.

  `position_ms` is where this stream begins, and it is 0 for one that begins at the
  start of the track. A source that resumes a track sets it to the point that its
  own `headers` ask for, and the player adds it to the time that it counts. A
  progress bar then shows the place in the whole track, and not the place in this
  request.

  `key` and `position_bytes` belong to `:download` alone. `key` is what the cache
  holds the file under, and `position_bytes` is the byte to begin at. A transport
  that reads no file leaves both absent.

  **A `:download` source needs no bitrate.** It gives `position_ms` for the count
  that a person reads, and `position_bytes` for the place in the file, and the two
  come from one stop. See `MyHiFi.Player.FileSource`.
  """
  @type playable :: %{
          uri: String.t(),
          headers: [{String.t(), String.t()}],
          transport: :http | :hls | :download,
          container: :none | :mpeg_ts | :ogg,
          format: :mp3 | :aac | :flac | :vorbis | :opus | :speex | :unknown,
          live?: boolean(),
          position_ms: non_neg_integer(),
          key: String.t() | nil,
          position_bytes: non_neg_integer() | nil
        }

  @doc "The name of this source, for a person to read."
  @callback title() :: String.t()

  @doc """
  The icon of this source.

  A source names its own icon, and each user interface draws that name in its own
  way. The web interface draws a heroicon, and the device screen draws a shape of
  its own. Neither one holds a list of the sources.

  The interfaces draw `:radio`, `:library`, `:podcast` and `:cloud` today. Any
  other name gives the default icon, so a new source works before an interface
  learns its icon.
  """
  @callback icon() :: atom()

  @doc """
  What this source holds, so a user interface knows which controls to draw.

  A radio station holds no place, so nothing moves through it and a skip control must
  be dead. A user interface cannot work that out, and it must not hold a list of the
  sources, so the source says it.

  - `:next` and `:previous` name the order that `next/1` and `previous/1` move
    through.
  - `:search` names `search/2`.
  - `:skip` names a track that a person can move inside.

  `MyHiFi.Player` reads this list as well. A skip of a source with no `:skip` gives
  `{:error, :cannot_skip}` and it reaches no pipeline, so the list is one fact and not
  a copy in each interface.

  This names what the source holds, and not what one track holds. A source of `:skip`
  can still hold a track that a person cannot move inside, and the player refuses that
  skip when it sees the track.

  A favourite is not in this list. Each entry carries `favourite?`, and that answer is
  the more exact one: internet radio marks a track and podcasts mark a container.
  """
  @callback capabilities() :: [capability()]

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
  The track after this one.

  The order is the one that a person sees in the browse list, because that is the
  order that they asked for. Podcasts move through the episodes of the same show, and
  internet radio moves through the favourite stations.

  A list of stations moves round, in the way that the presets of a stereo do. A list
  of episodes ends, and the last one gives `{:error, :no_more}`.

  `{:error, :no_more}` and `{:error, :not_supported}` are different answers. A source
  with no order gives the second one, and `capabilities/0` says so before a caller
  asks.
  """
  @callback next(ref()) :: {:ok, ref()} | {:error, term()}

  @doc """
  The track before this one.

  See `next/1` for the order, and for the two errors.
  """
  @callback previous(ref()) :: {:ok, ref()} | {:error, term()}

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

  The entry is a track or a container. Internet radio marks a station, and
  podcasts subscribe to a show. A source that marks one kind gives
  `{:error, :not_supported}` for the other.
  """
  @callback favourite(ref(), boolean()) :: :ok | {:error, term()}

  @doc """
  Note where a person stopped inside a track.

  The player calls this when it stops, when it enters standby, and when a track
  reaches its end. A live stream has no position, so internet radio does nothing.

  This is a notice and not a question, so a source that keeps no position gives
  `:ok` and not an error. `search/2` and `favourite/2` give
  `{:error, :not_supported}` instead, and the reason for the difference is the user
  interface: it must know whether to draw a search field and a star, and it draws
  no control at all for a position.

  The player holds no knowledge of what a position means to a service. It gives the
  place that it saw, and the source decides whether to keep it.

  A place holds two numbers, and `bytes` is the reason that a resume is exact. A
  time alone needs a bitrate to become a byte offset, and 11 of 46 real episodes
  hold more than one bitrate. `bytes` is nil for a stream that no reader counts
  bytes of, such as a live station.
  """
  @callback store_position(ref(), place()) :: :ok | {:error, term()}

  @doc """
  Note that a track reached its end.

  The player calls this in place of `store_position/2` when a track ends by itself.
  A source that holds a played mark writes it here.

  The player starts a live stream again when it ends, because a person expects the
  music to come back. This therefore never reaches a source of live streams, and
  internet radio implements it and does nothing.
  """
  @callback finished(ref()) :: :ok | {:error, term()}

  @doc """
  The values that a person can change for this source.

  A settings page draws one control for each field, and it holds no knowledge of
  which source it shows. The countries of the station list and the key of the
  Podcast Index are both fields of this kind.

  A source reads its own current values here, so `description` can hold a count or
  a state that changes. `value` is nil for a field that a page must never show
  again, such as the secret of an index, and `write_only?` then says so.

  A source with nothing to change leaves this out. See `settings/1`.
  """
  @callback settings() :: [field()]

  @doc """
  Write the values that a person typed.

  The map holds the `key` of each field of `settings/0`, and the text of it. The
  source checks the values, writes what it accepts, and gives one sentence for a
  person to read.

  The check belongs here and not in a page. "Name at least one country" and "the
  index refused that key" are both facts of one service, and a settings page holds
  no knowledge of any service.
  """
  @callback put_settings(%{String.t() => String.t()}) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc """
  The controls of this source that do something, and change no value.

  "Ask for the stations now" and "Remove the key" are both of this kind. A page
  draws one button for each one, and `run_settings_action/1` runs it.

  A source with no such control leaves this out. See `settings_actions/1`.
  """
  @callback settings_actions() :: [action()]

  @doc """
  Run one control of `settings_actions/0`.

  The name comes from that list. The answer is one sentence for a person to read.
  """
  @callback run_settings_action(String.t()) :: {:ok, String.t()} | {:error, String.t()}

  @optional_callbacks settings: 0,
                      put_settings: 1,
                      settings_actions: 0,
                      run_settings_action: 1

  @doc """
  Every source that this firmware holds.

  A new source joins this list, and the web interface and the device interface then
  show it without a change. A test sets `:sources` to give a source of its own.

  The order decides the order of the controls in the top row of the web interface,
  and the first one is what a person sees at an address that names no source.
  """
  @spec all() :: [module()]
  def all do
    Application.get_env(:my_hi_fi, :sources, [
      MyHiFi.Source.InternetRadio,
      MyHiFi.Source.Podcasts
    ])
  end

  @doc """
  Put a source in use, or take it out of use.

  This writes the setting and nothing else. `MyHiFi.Playback.enable_source/2` is
  what a user interface calls, because it also stops the player when the source
  that plays goes out of use.
  """
  @spec enable(module(), boolean()) :: :ok
  def enable(module, enabled?) do
    MyHiFi.Settings.put!(enabled_key(module), to_string(enabled?))

    :ok
  end

  @doc """
  Every source that a person has left in use.

  A user interface shows these, and `all/0` holds the rest as well. The two lists
  are different because a name in the settings must still name a source that a
  person has taken out of use, and because a settings page must be able to put one
  back in use.
  """
  @spec enabled() :: [module()]
  def enabled, do: Enum.filter(all(), &enabled?/1)

  @doc """
  Whether a person has left this source in use.

  A source that no person has changed is in use, so a new source works on the
  first start.
  """
  @spec enabled?(module()) :: boolean()
  def enabled?(module) do
    case MyHiFi.Settings.fetch(enabled_key(module)) do
      {:ok, %{value: "false"}} -> false
      _other -> true
    end
  end

  @doc """
  The settings key that says whether a source is in use.

      iex> MyHiFi.Source.enabled_key(MyHiFi.Source.InternetRadio)
      "source.internet-radio.enabled"
  """
  @spec enabled_key(module()) :: String.t()
  def enabled_key(module), do: "source." <> slug(module) <> ".enabled"

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
  Write the values that a person typed for one source.

  See `c:put_settings/1`. A source that holds no settings gives an error, so a page
  that draws no control also writes none.
  """
  @spec put_settings(module(), %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, String.t()}
  def put_settings(module, values) do
    if implements?(module, :put_settings, 1) do
      module.put_settings(values)
    else
      {:error, "#{module.title()} holds nothing to change."}
    end
  end

  @doc """
  Run one control of one source.

  See `c:run_settings_action/1`.
  """
  @spec run_settings_action(module(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run_settings_action(module, name) do
    if implements?(module, :run_settings_action, 1) do
      module.run_settings_action(name)
    else
      {:error, "#{module.title()} holds no such control."}
    end
  end

  @doc """
  The values that a person can change for one source.

  See `c:settings/0`. A source that implements no settings gives an empty list, so
  a settings page needs no knowledge of which sources hold settings.
  """
  @spec settings(module()) :: [field()]
  def settings(module) do
    if implements?(module, :settings, 0), do: module.settings(), else: []
  end

  @doc """
  The controls of one source that do something.

  See `c:settings_actions/0`.
  """
  @spec settings_actions(module()) :: [action()]
  def settings_actions(module) do
    if implements?(module, :settings_actions, 0), do: module.settings_actions(), else: []
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

  # `settings/0` and the three beside it are optional, so a source that holds
  # nothing to change writes nothing. `function_exported?/3` alone answers false
  # for a module that no call has loaded yet.
  defp implements?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end
