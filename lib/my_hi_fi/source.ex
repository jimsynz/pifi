defmodule MyHiFi.Source do
  @moduledoc """
  Where the music comes from.

  A source shows a tree. A container holds more entries, and a track plays. The
  player and each user interface walk that tree, so neither one holds knowledge of
  any particular service.

  `MyHiFi.Source.InternetRadio`, `MyHiFi.Source.Podcasts` and
  `MyHiFi.Source.Jellyfin` are the sources today. Spotify, Plex and Squeezecast come
  later, and each one is a module that implements this behaviour and changes nothing
  else.
  """

  require Logger

  # **What a container held before a source could say otherwise.** The oldest item
  # first, because a person who presses one episode of a show queues the rest behind
  # it, so the order of the list is the order that they hear and a series makes sense
  # from the start. See `inside/2`.
  @default_inside %{
    facts: [:published_at],
    order: {"Date", "published_at"},
    sort: [published_at: :asc, sorted_title: :asc]
  }

  # The list under a facet, which no container holds. A facet of this firmware names a
  # country, a tag or a category, and the rows of one are the popular ones first: the
  # sync of Radio Browser writes the click count of a station into `rank`.
  @default_under_facet %{
    facts: [:subtitle],
    order: {"Popularity", "rank"},
    sort: [rank: :desc, sorted_title: :asc]
  }

  @typedoc """
  What a source holds, beyond the tree that every source holds.

  See `c:capabilities/0`.
  """
  @type capability :: :refresh | :search | :skip

  @typedoc """
  One value of a source that a person can change.

  `key` names the field to `put_settings/1`, and it is also the name of the control
  on a page. `type` decides the control: `:text` shows what it holds, `:password`
  hides it, and `:number` takes a whole number. Each one is a type that
  `MyHiFiWeb.CoreComponents.input/1` draws, and the settings page passes it through
  with no rule of its own.

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
          type: :number | :password | :text,
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

  The interfaces draw `:radio`, `:library`, `:podcast`, `:cloud` and `:jellyfin`
  today. Any other name gives the default icon, so a new source works before an
  interface learns its icon.

  **A name may be the mark of one service, as `:jellyfin` is.** A person reads the
  top row and finds the service that they set up, by the mark that every other client
  of it shows them. The web interface draws such a mark in the way that it draws a
  heroicon, so it takes the accent colour and the list of names stays one list. The
  mark belongs to the project that made it, and it carries its own licence.
  """
  @callback icon() :: atom()

  @doc """
  What this source holds, so a user interface knows which controls to draw.

  A radio station holds no place, so nothing moves through it and a skip control must
  be dead. A user interface cannot work that out, and it must not hold a list of the
  sources, so the source says it.

  - `:refresh` names `refresh/1`.
  - `:search` names `search/1`.
  - `:skip` names a track that a person can move inside.

  Next and previous are not in this list. `MyHiFi.Playback.Queue` holds the order, so
  every track that plays holds them and no source takes part.

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

  @typedoc """
  A read that a user interface runs, pages through and draws.

  `query` is over `MyHiFi.Playback.Item` or over `MyHiFi.Playback.Facet`, and `kind`
  says which. A page gives it to `Cinder`, which holds the loading state, the sort, the
  filters and the page controls.

  Below the roots the tree needs no source at all. A row of `Facet` opens into the
  items that link to it, and an item of the kind `:container` opens into the items whose
  `parent_id` names it. Those two rules serve every source.

  ## `order`, and why a sort of the query is not enough

  **Cinder keeps only the sorts of `query` that name a column that the page draws, and
  it drops the rest.** A query that sorts by `rank` and then by `title` therefore loses
  the rank, because the page draws a column of the title alone, and a list of the most
  popular stations comes back in the order of the alphabet.

  `order` is how a listing says that it holds a second order. It is a name and a field,
  such as `{"Popularity", "rank"}`, and the page draws a sort control for it. Cinder
  then keeps that sort, and a person can change it. A listing that sorts by the title
  and nothing else leaves `order` out.
  """
  @type listing :: %{
          required(:query) => Ash.Query.t(),
          required(:kind) => :item | :facet,
          optional(:order) => {String.t(), String.t()},
          optional(:number?) => boolean(),
          optional(:facts) => [fact()]
        }

  @typedoc """
  One thing that a row of a list says about an item, beside its title.

  **A source names the facts, and each surface draws them.** A page of the web
  interface holds a row across a browser and `MyHiFi.DeviceUi` holds one on a screen of
  240 pixels, so "44m left" and "44 min" are one fact drawn two ways. A source that
  gave text for a row would also be in the render path, because the time left of an
  episode moves while it plays.

  Each name is a field of `MyHiFi.Playback.Item`, and `{:text, "…"}` is the way to say
  something that no field holds. A surface that meets a fact it does not know draws
  nothing for it, so a new fact reaches a screen when that screen learns it and never
  as an error.
  """
  @type fact ::
          :subtitle
          | :published_at
          | :release_year
          | :duration_ms
          | :remaining_ms
          | {:text, String.t()}

  @typedoc """
  What a source says about the items inside one of its containers.

  The page builds the query, because "the items whose container is this one" is the
  same read for every source. Everything else belongs to the source: `sort` is what
  `Ash.Query.sort/2` takes, `order` names the sort control that a person presses, and
  `number?` says that a row draws the place of the item in front of its title.
  """
  @type inside :: %{
          optional(:number?) => boolean(),
          optional(:facts) => [fact()],
          optional(:sort) => keyword(),
          optional(:order) => {String.t(), String.t()}
        }

  @doc """
  The branches at the top of the tree, in the order that a person reads them.

  Each pair is a name and the read behind it. A source names its own branches, and
  everything below them is generic.
  """
  @callback roots() :: [{String.t(), listing()}]

  @doc """
  How the items inside one container read, and in what order.

  An album holds its tracks by number, and a show holds its episodes by date with the
  newest first. **Neither of those is a rule that a page can hold**, because a page
  holds no knowledge of any source: it sorted every container by date and labelled the
  control "Date", so every album of a Jellyfin library listed alphabetically.

  **`nil` is the list under a facet**, which no container holds: a country of Radio
  Browser, or a category of the Podcast Index. A source that implements none gets the
  default of `inside/2` for either case.
  """
  @callback listing(MyHiFi.Playback.Item.t() | nil) :: inside()

  @doc """
  How many items of a marked container this device holds on the card, newest first.

  **A show holds hundreds of episodes and a person wants the newest few.** A source
  whose items keep their place therefore names a number, and `MyHiFi.Source.Podcasts`
  reads it from a setting that a person changes.

  `:all` is every item that the container holds, and an album of songs is that: a
  person who marks one wants the record and not three tracks of it.

  A source that implements none gets `:all`. See `MyHiFi.Playback.FavouriteAudio`.
  """
  @callback hold_limit() :: pos_integer() | :all

  @doc """
  A person opened one container.

  A source that must reach a service when that happens implements this.
  `MyHiFi.Source.Podcasts` reads the feed of a show whose local copy is old.

  It runs for its effect, and a page draws what the catalogue holds whether it answers
  or not.
  """
  @callback opened(MyHiFi.Playback.Item.t()) :: :ok

  @doc """
  A person asked for the service to be read again, for one container.

  `c:opened/1` reads a feed whose local copy is old, and a schedule reads it as well.
  Neither one answers a person who knows that a publisher wrote something a moment ago,
  so this reads it now.

  It runs for its effect, and it may give the work to a job. A source that finishes the
  read publishes `MyHiFi.Event.Source.Changed`, and a page that shows that container
  reads it again.

  `capabilities/0` names `:refresh` for a source that holds this.
  """
  @callback refresh(MyHiFi.Playback.Item.t()) :: :ok | {:error, term()}

  @doc """
  What a person calls the items of this source, for each kind that it holds.

  `:container` names an item that holds other items, and `:track` names one that plays.
  A source that holds no container leaves that kind out: internet radio gives
  `[track: "Stations"]`, and podcasts gives `[container: "Shows", track: "Episodes"]`.

  A user interface reads the name of a kind, and it draws no control at all for a source
  that holds one kind. There is nothing to choose between.

  The words are plural, because each one names a list and not one row.
  """
  @callback kinds() :: [{:container | :track, String.t()}]

  @doc """
  The items that a search reads.

  It gives a query in the way that `c:roots/0` gives one, and `MyHiFiWeb.SearchLive`
  matches the text of the person against it. The query therefore names the items of the
  source, and it holds no text of its own.

  **A source may reach a service before it answers.** The catalogue holds what a device
  has read, and a service holds more than that. `MyHiFi.Source.Podcasts` asks the
  Podcast Index, and it writes what the index names, so the query then finds it. This is
  why the callback gets the text.

  `capabilities/0` names `:search` for a source that holds this.
  """
  @callback search(String.t()) :: Ash.Query.t()

  @doc """
  Turn an item into something that the player can play.

  This is the one thing that only a source can do. A station gives the address of a
  stream, and an episode gives the file that the cache holds, so the shape of the
  answer is the same and the way to it is not. See `t:playable/0`.
  """
  @callback resolve(MyHiFi.Playback.Item.t()) :: {:ok, playable()} | {:error, term()}

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

  @doc """
  Whether this source holds what it needs to reach its service.

  **This is not `enabled?/1`.** A person answers that one, and this one is a fact about
  the source: podcasts need a key of the Podcast Index, and a device that holds none can
  reach nothing. `MyHiFi.AutoSync` asks both before it runs the work of a source, so a
  device with no key asks the index nothing and writes no job that can only fail.

  A source that needs no such thing leaves this out, and `ready?/1` then gives `true`.
  """
  @callback ready?() :: boolean()

  # A source with no search leaves `search/1` out, and it names no `:search` in
  # `c:capabilities/0`.
  @optional_callbacks hold_limit: 0,
                      listing: 1,
                      opened: 1,
                      ready?: 0,
                      refresh: 1,
                      search: 1,
                      settings: 0,
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
      MyHiFi.Source.Podcasts,
      MyHiFi.Source.Jellyfin
    ])
  end

  @doc """
  Remember the source that a person is looking at.

  The top row of the faceplate lights one control, and that control is the source
  switch of this device. A person who turns the device off and on again finds the
  switch where they left it, in the same way that the selector of an amplifier stays
  where a hand put it.

  It writes nothing when the setting names this source already. A move through the
  tree of one source therefore costs no write, and the SD card lasts longer.

  **It raises nothing.** No person asked for this write: it is what the device
  remembers while they look at a list. A write that fails must therefore leave the
  switch where it was and let them keep reading. `enable/2` raises, because a person
  pressed a control there and must be told when it did nothing.
  """
  @spec choose(module()) :: :ok
  def choose(module) do
    slug = slug(module)

    if chosen_slug() != slug do
      case MyHiFi.Settings.put(chosen_key(), slug) do
        {:ok, _setting} ->
          :ok

        {:error, reason} ->
          Logger.warning("The device did not remember the source: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc """
  The source that a person chose last.

  It gives the first source in use when the choice names a source that this firmware
  no longer holds, or one that a person took out of use. A selector lands on the first
  input in the same way when the socket behind it is empty. It gives `nil` when no
  source is in use at all.
  """
  @spec chosen() :: module() | nil
  def chosen do
    with slug when is_binary(slug) <- chosen_slug(),
         {:ok, module} <- from_slug(slug),
         true <- enabled?(module) do
      module
    else
      _other -> List.first(enabled())
    end
  end

  @doc """
  The settings key that holds the source that a person chose last.

      iex> MyHiFi.Source.chosen_key()
      "source.chosen"
  """
  @spec chosen_key() :: String.t()
  def chosen_key, do: "source.chosen"

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
  Whether a source holds what it needs to reach its service.

  A source that names no `c:ready?/0` needs nothing, so this gives `true` for it. See
  that callback for the difference between this and `enabled?/1`.
  """
  @spec ready?(module()) :: boolean()
  def ready?(module) do
    if implements?(module, :ready?, 0), do: module.ready?(), else: true
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
  Read the service of one container again.

  See `c:refresh/1`. A source that reads no service gives an error, so a page that
  draws no control also runs none.
  """
  @spec refresh(module(), MyHiFi.Playback.Item.t()) :: :ok | {:error, term()}
  def refresh(module, item) do
    if implements?(module, :refresh, 1) do
      module.refresh(item)
    else
      {:error, "#{module.title()} reads nothing again."}
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
  How many items of a marked container of this source the card holds.

  See `c:hold_limit/0`. A source that names none holds every one.

      iex> MyHiFi.Source.hold_limit(MyHiFi.Source.InternetRadio)
      :all

  """
  @spec hold_limit(module()) :: pos_integer() | :all
  def hold_limit(module) do
    if implements?(module, :hold_limit, 0), do: module.hold_limit(), else: :all
  end

  @doc """
  How the items inside one container read, and in what order.

  See `c:listing/1`. A source that names none gets the date of the item, oldest first,
  which is what every container of this firmware held before a source could say
  otherwise, and the popular ones first under a facet.

      iex> MyHiFi.Source.inside(MyHiFi.Source.Podcasts, %MyHiFi.Playback.Item{}).order
      {"Date", "published_at"}

      iex> MyHiFi.Source.inside(MyHiFi.Source.Podcasts, nil).order
      {"Popularity", "rank"}

  """
  @spec inside(module(), MyHiFi.Playback.Item.t() | nil) :: inside()
  def inside(module, item) do
    if implements?(module, :listing, 1),
      do: module.listing(item),
      else: default_inside(item)
  end

  defp default_inside(nil), do: @default_under_facet
  defp default_inside(_item), do: @default_inside

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
  Ask for one scheduled action of a source, and say whether it went into the queue.

  It gives `:queued` for a job that this call put in, and `:running` for one that was
  there already. **A caller must read the answer and tell the person which it was.**
  `AshOban.schedule/2` gives the job that it finds when a job is already there, and it
  raises nothing, so a control that ignores the answer says that it read a library
  whether it did or not.

  A scheduled action is unique, and `executing` counts. A device that stopped in the
  middle of a read therefore holds a job that no process runs, and every later ask
  finds that one. `Oban.Lifeline` moves such a job back, and until it does this is what
  keeps a settings page truthful. See `config/config.exs`.
  """
  @spec ask_for_job(Ash.Resource.t(), atom()) :: :queued | :running
  def ask_for_job(resource, action) do
    if AshOban.schedule(resource, action).conflict?, do: :running, else: :queued
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

  defp chosen_slug do
    case MyHiFi.Settings.fetch(chosen_key()) do
      {:ok, %{value: slug}} -> slug
      {:error, _reason} -> nil
    end
  end

  # `settings/0` and the three beside it are optional, so a source that holds
  # nothing to change writes nothing. `function_exported?/3` alone answers false
  # for a module that no call has loaded yet.
  defp implements?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end
