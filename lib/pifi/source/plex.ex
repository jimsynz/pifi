defmodule PiFi.Source.Plex do
  @moduledoc """
  The music library of one Plex Media Server, on the local network.

  The tree has six branches under the root.

      Artists             every artist of the library
        an artist         the albums of that artist
          an album        the tracks of that album
      Albums              every album of the library
      Recently added      the albums that the server took in last
      Genres              every genre of the library
        a genre           the albums of that genre
      Record labels       every record label of the library
        a record label    the albums of that label
      Favourites          the artists, the albums and the tracks that a person marked

  An artist and an album are containers, and a track plays. See `PiFi.Plex.Fill` for
  the shape of the tree, and `PiFi.Plex.Server` for the reads.

  ## It browses the catalogue and not the server

  `PiFi.Plex.Sync` copies the library on to the card, so a person browses their music
  when the server is asleep and when the network is down. This is the shape that
  internet radio uses, and it is the reason that `opened/1` and `refresh/1` are absent:
  no branch of this source reaches the server, and there is nothing for either one to
  read.

  `resolve/1` is the one function that needs the server, and it needs it because the
  address of the audio carries the access token of the moment.

  ## Linking, and the two steps of it

  **A Plex token comes from plex.tv and from nowhere else**, so this source reaches the
  internet once and the household for ever after. The device asks plex.tv for a code, a
  person types that code at <https://plex.tv/link>, and plex.tv then gives an account
  token. No password reaches this device.

  **The person says when they have typed the code, and no timer does.** A device cannot
  push a change to a settings page, so a poll behind the page would hold a job of the
  queue for the minutes that a code lives and a person would still have to look again
  to see the answer. They press `Link this account`, they read the code in the
  description, they type it, and they press `Finish linking`. The one who knows when
  the code went in is the one who typed it.

  ## The device finds the server, and a person names it only when there are two

  Plex is not Jellyfin in this way as well: a person does not know the address of their
  server, and they do not have to. `Finish linking` reads the servers of the account
  and takes the one that answers on the local network.

  A household with more than one server writes the name of each into the description,
  and a person types the one that holds the music into `Server name`. The device then
  uses that one. **`Server name` is therefore empty for almost every person**, and the
  field exists for the household that needs it.

  ## A track keeps no place, and that decides what a mark reads

  A song is not an episode of a podcast. `PiFi.Plex.Fill` therefore writes
  `keeps_place?` as false on each track, and `PiFi.Playback.Item` reads that when a
  person marks an album: it reads the audio of a track that keeps no place, and it
  leaves a subscribed show alone.

  ## A track of a codec that this firmware cannot decode

  The pipeline decodes MP3, FLAC, AAC in ADTS and Vorbis in Ogg as the server holds
  them. **Everything else is a conversion**, and
  `PiFi.Plex.Server.transcode_url/2` is the address of it. A sample of one real
  library on 2026-09-14 gave 14% AAC in MP4, and a library of ALAC or WMA would lean
  on it further.

  **This is the one path of this source that makes a server do work**, and it is a
  last answer and not a first one. A track that this device reads as it is costs the
  server nothing, so the conversion happens for the codecs that are left and for no
  other. `PiFi.Plex.Fill` writes `:unknown` for such a track, and `:hls` as its
  transport, so the card holds no copy of a file that nothing here can read.
  """

  @behaviour PiFi.Source

  require Ash.Query

  alias PiFi.Playback.Facet
  alias PiFi.Playback.Item
  alias PiFi.Player.Hls
  alias PiFi.Plex.Companion
  alias PiFi.Plex.Fill
  alias PiFi.Plex.Server
  alias PiFi.Plex.Sync

  @source "plex"

  @impl PiFi.Source
  def title, do: "Plex"

  # The mark of the service itself, and not the shelf that `:library` draws. A person
  # who reads the top row finds the service that they set up, by the chevron that every
  # other Plex client shows them. See `PiFiWeb.CoreComponents` and
  # `assets/vendor/brand.js`.
  @impl PiFi.Source
  def icon, do: :plex

  # **A skip works for most of a library of this source, and not for all of it.**
  # `PiFi.Player.Skip` reads the frames of MP3 and of AAC in ADTS, and it bisects a
  # FLAC file. Vorbis in Ogg is the one codec that it cannot move inside, and a track
  # that the server converts is not a file at all, so `PiFi.Plex.Fill` writes `:hls`
  # for it and `PiFi.Player.skippable?/1` refuses the skip with no rule of its own.
  #
  # **A search reaches no server.** The catalogue holds the whole library, because
  # `PiFi.Plex.Sync.Library` reads every artist, album and track of it, so a search
  # of this source is a read of the card and it works when the server is off.
  @impl PiFi.Source
  def capabilities, do: [:search, :skip]

  @impl PiFi.Source
  def kinds, do: [container: "Albums", track: "Tracks"]

  @impl PiFi.Source
  def roots do
    [
      {"Artists", %{query: artists_query(), kind: :item, title_label: "Name"}},
      {"Albums", %{query: albums_query(), kind: :item, facts: [:subtitle, :release_year]}},
      {"Recently added",
       %{query: recently_added_query(), kind: :item, facts: [:subtitle, :release_year]}},
      {"Genres", %{query: facet_query(Fill.genre_key()), kind: :facet}},
      {"Record labels", %{query: facet_query(Fill.record_label_key()), kind: :facet}},
      {"Favourites", %{query: favourites_query(), kind: :item, facts: [:subtitle, :release_year]}}
    ]
  end

  # A genre and a record label of this source are both facets, in the way that a country
  # of a station is one, so each branch is a plain read of the facets and the page below
  # it needs no rule of its own. See `PiFi.Plex.Fill.genre_key/0` and
  # `PiFi.Plex.Fill.record_label_key/0`.
  defp facet_query(key), do: Ash.Query.for_read(Facet, :by_key, %{key: key})

  @doc """
  An album reads its tracks in the order that the record plays them.

  **The order is one column and not two.** `place` of the item carries the disc and the
  number as one number, because `Cinder.QueryBuilder` unsets the sort of a query when a
  person presses a sort control and applies the one column that they pressed: a sort of
  `[disc: :asc, number: :asc]` became `number` alone, and a set of two discs read 1-01,
  2-01, 1-02, 2-02. A server that names neither number leaves `place` absent, SQLite
  reads that as the smallest value, and the title then decides.

  An artist contains albums, and an album row shows its artist and its release year. An
  album contains tracks, and a track row shows its artist and its duration.
  """
  @impl PiFi.Source
  def listing(item) do
    %{
      number?: true,
      facts: listing_facts(item),
      sort: [place: :asc, sorted_title: :asc],
      order: {"Track", "place"}
    }
  end

  defp listing_facts(%{kind: :container, parent_id: nil}), do: [:subtitle, :release_year]
  defp listing_facts(_item), do: [:subtitle, :duration_ms]

  # An artist is the one container of this source with no parent, so this branch needs
  # no facet and no column of its own. See `PiFi.Plex.Fill`.
  defp artists_query do
    Item
    |> Ash.Query.filter(source == ^@source and kind == :container and is_nil(parent_id))
    |> Ash.Query.sort(sorted_title: :asc)
  end

  defp albums_query do
    Item
    |> Ash.Query.filter(source == ^@source and kind == :container and not is_nil(parent_id))
    |> Ash.Query.sort(sorted_title: :asc)
  end

  # **The date comes from the server and not from this device.** `added_at` carries
  # `addedAt` of Plex, so a person who writes a new card still reads the record that
  # they added last week at the top. `inserted_at` would give every album of the library
  # one date, which is the date of the first read.
  #
  # An album with no date comes last. SQLite reads a null as the smallest value, so
  # `:desc` puts it after every album that names one, which is where a person who asked
  # for the newest expects it.
  defp recently_added_query do
    Item
    |> Ash.Query.filter(source == ^@source and kind == :container and not is_nil(parent_id))
    |> Ash.Query.sort(added_at: :desc)
  end

  defp favourites_query do
    Item
    |> Ash.Query.filter(source == ^@source and favourite? == true)
    |> Ash.Query.sort(sorted_title: :asc)
  end

  defp tracks_query do
    Item
    |> Ash.Query.filter(source == ^@source and kind == :track)
    |> Ash.Query.sort(sorted_title: :asc)
  end

  @impl PiFi.Source
  def search(_text) do
    Item
    |> Ash.Query.filter(source == ^@source)
    |> Ash.Query.sort(sorted_title: :asc)
  end

  # **An artist and an album are both containers, so `kinds/0` cannot tell them
  # apart.** A person who searches for a name wants the artist above the records of it,
  # and a heading that read `Albums` for both would say the wrong word for half of the
  # rows. See `c:PiFi.Source.search_groups/1`.
  @impl PiFi.Source
  def search_groups(_text) do
    [
      {"Artists", %{query: artists_query(), kind: :item, title_label: "Name"}},
      {"Albums", %{query: albums_query(), kind: :item, facts: [:subtitle, :release_year]}},
      {"Tracks", %{query: tracks_query(), kind: :item, facts: [:subtitle, :duration_ms]}}
    ]
  end

  @impl PiFi.Source
  def resolve(%{kind: :track} = item), do: playable(item, nil)

  def resolve(item), do: {:error, {:not_a_track, item.id}}

  @doc """
  Turn a track into something that the player can play, with a link already read.

  A caller that reads many tracks of this source reads the link once and passes it
  here, so a loop of many tracks makes one read of the settings and not three for each
  one. See `PiFi.Playback.FavouriteAudio`.
  """
  @spec resolve(PiFi.Playback.Item.t(), map() | nil) ::
          {:ok, PiFi.Source.playable()} | {:error, term()}
  def resolve(%{kind: :track} = item, link), do: playable(item, link)

  def resolve(item, _link), do: {:error, {:not_a_track, item.id}}

  # A device with no link reaches nothing, so `PiFi.AutoSync` writes no job that can
  # only fail.
  @impl PiFi.Source
  def ready?, do: Server.configured?()

  @impl PiFi.Source
  def settings do
    [
      %{
        key: "server_name",
        title: "Server name",
        description: state_description(),
        link: %{href: "https://www.plex.tv", title: "plex.tv"},
        type: :text,
        value: Server.server_name(),
        write_only?: false
      }
    ]
  end

  @impl PiFi.Source
  def put_settings(%{"server_name" => name}) do
    case present(name) do
      :error ->
        Server.forget_server_name()

        {:ok, "The device uses the first server of your account that answers here."}

      {:ok, name} ->
        choose(name)
    end
  end

  def put_settings(_values), do: {:error, "Give the name of the server that holds your music."}

  @impl PiFi.Source
  def settings_actions do
    cond do
      Server.configured?() -> [read_library(), player(), remove_link()]
      Server.linked_to_account?() -> [choose_server(), remove_link()]
      not is_nil(Server.pending_code()) -> [finish_link(), link()]
      true -> [link()]
    end
  end

  # **A player is two things, and a person asks for both with one control.** The device
  # must listen, and the account must know where to reach it, because a controller reads
  # the players of an account and Plexamp on a telephone reads nothing else.
  @impl PiFi.Source
  def run_settings_action("start_player") do
    if Server.registered_as_player?(), do: opened_player(), else: asked_to_be_a_player()
  end

  def run_settings_action("finish_player") do
    case Server.finish_link_as_player(Companion.addresses()) do
      {:ok, :linked} ->
        Companion.enable(true)

        {:ok, "This device is a Plex player now. Your Plex applications can find it."}

      {:ok, :waiting} ->
        {:error, "Type the code #{Server.player_code()} at plex.tv/link first."}

      {:error, :ran_out_of_time} ->
        {:error, "That code ran out of time. Press Be a Plex player again."}

      {:error, reason} ->
        {:error, "plex.tv did not answer: #{inspect(reason)}"}
    end
  end

  def run_settings_action("stop_player") do
    Companion.enable(false)

    {:ok, "This device is no longer a Plex player."}
  end

  def run_settings_action("link") do
    case Server.start_link_to_account() do
      {:ok, %{code: code}} ->
        {:ok, "Type the code #{code} at plex.tv/link, and then press Finish linking."}

      {:error, reason} ->
        {:error, "plex.tv did not answer: #{inspect(reason)}"}
    end
  end

  def run_settings_action("finish_link") do
    case Server.link_state() do
      {:ok, :linked} -> choose_first()
      {:ok, :waiting} -> {:ok, waiting_message()}
      {:error, :unknown_pin} -> forget_code()
      {:error, :no_pin} -> {:error, "Press Link this account first."}
      {:error, reason} -> {:error, "plex.tv did not answer: #{inspect(reason)}"}
    end
  end

  def run_settings_action("choose_server"), do: choose_first()

  def run_settings_action("read_library") do
    case PiFi.Source.ask_for_job(Sync, :sync_library) do
      :queued ->
        {:ok, "The device reads your library now. It takes a few minutes for a large one."}

      :running ->
        {:ok,
         "A read is already running, and it takes a while for a large library. " <>
           "A read that stopped without finishing starts again within two hours."}
    end
  end

  def run_settings_action("remove_link") do
    Server.forget()

    {:ok, "This device is not linked now. Your music stays in the list until the next read."}
  end

  def run_settings_action(_name), do: {:error, "Plex has no such control."}

  defp link do
    %{
      name: "link",
      title: "Link this account",
      description: "The device asks plex.tv for a code. You then type that code at plex.tv/link.",
      icon: :cloud
    }
  end

  defp finish_link do
    %{
      name: "finish_link",
      title: "Finish linking",
      description: "Press this after you type the code at plex.tv/link.",
      icon: :refresh
    }
  end

  defp choose_server do
    %{
      name: "choose_server",
      title: "Find my server",
      description: "The device asks your account which servers answer on this network.",
      icon: :refresh
    }
  end

  # **The control says what it will do and not what it is**, because a person who turns
  # this on opens a port on their device. The three states follow the link of the
  # library: a person asks, a person types a code, and then it is done. See
  # `PiFi.Plex.Companion`.
  # **A device that is a player already asks no person to authorise it again.** The
  # account holds the row for as long as a person leaves it there, so a person who turns
  # the player off and on again wants the port open and nothing else.
  defp player do
    cond do
      Companion.enabled?() -> stop_player()
      Server.registered_as_player?() -> start_player()
      Server.player_code() -> finish_player()
      true -> start_player()
    end
  end

  # The account holds this device already, so this opens the port and the announcement
  # tells the account where to find it. See `PiFi.Plex.Companion.Announcement`.
  defp opened_player do
    Companion.enable(true)

    if Companion.running?() do
      {:ok, "This device is a Plex player now, on port #{Companion.port()}."}
    else
      {:error, "The device could not listen on port #{Companion.port()}."}
    end
  end

  defp asked_to_be_a_player do
    case Server.start_link_as_player() do
      {:ok, code} ->
        {:ok, "Type the code #{code} at plex.tv/link, and then press Finish the player."}

      {:error, reason} ->
        {:error, "plex.tv did not answer: #{inspect(reason)}"}
    end
  end

  defp start_player do
    %{
      name: "start_player",
      title: "Be a Plex player",
      description:
        "Another Plex application can then control this device, and finds it on your " <>
          "network by itself. The device listens on port #{Companion.port()} while it is on.",
      icon: :radio
    }
  end

  defp finish_player do
    %{
      name: "finish_player",
      title: "Finish the player",
      description: "Type the code #{Server.player_code()} at plex.tv/link, and press this.",
      icon: :refresh
    }
  end

  defp stop_player do
    %{
      name: "stop_player",
      title: "Stop being a Plex player",
      description: "The device closes its ports and no other Plex application can control it.",
      icon: :radio
    }
  end

  defp read_library do
    %{
      name: "read_library",
      title: "Read the library now",
      description: "A daily job also does this by itself.",
      icon: :refresh
    }
  end

  defp remove_link do
    %{
      name: "remove_link",
      title: "Remove the link",
      description: "The device forgets both tokens and the server. Your music stays in the list.",
      icon: :remove
    }
  end

  # A person who names no server gets the first one that answers on this network, and
  # that is every household with one server.
  defp choose_first do
    with_servers(fn servers ->
      case Enum.find(servers, &(not is_nil(&1.address))) do
        nil -> {:error, no_local_message(servers)}
        server -> took(server, servers)
      end
    end)
  end

  defp choose(name) do
    with_servers(fn servers ->
      case Enum.find(servers, &(&1.name == name and not is_nil(&1.address))) do
        nil -> {:error, "No server of your account answers here under the name #{name}."}
        server -> took(server, servers)
      end
    end)
  end

  defp with_servers(chooser) do
    case Server.servers() do
      {:ok, []} ->
        {:error, "Your account lists no server. Start Plex on the machine that holds your music."}

      {:ok, servers} ->
        chooser.(servers)

      {:error, :not_linked} ->
        {:error, "Press Link this account first."}

      {:error, :unauthorised} ->
        {:error, "plex.tv refused that token. Press Remove the link, and link again."}

      {:error, reason} ->
        {:error, "plex.tv did not answer: #{inspect(reason)}"}
    end
  end

  # **The read starts here, and a person presses nothing more.** A person who has just
  # named their server wants their music, and `PiFi.AutoSync` would reach this within
  # the hour and not now. An earlier version wrote the server and said that it read the
  # library, and it queued nothing: a board on 2026-09-14 named the server and then
  # said that the library holds 0 tracks.
  defp took(server, servers) do
    Server.use_server(server)
    PiFi.Source.ask_for_job(Sync, :sync_library)

    {:ok, "The device uses #{server.name}. It reads your library now.#{others(server, servers)}"}
  end

  # A household with one server reads nothing more, and one with two reads which other
  # names it can type into Server name.
  defp others(chosen, servers) do
    case Enum.reject(servers, &(&1.name == chosen.name)) do
      [] -> ""
      rest -> " Your account also lists #{names(rest)}."
    end
  end

  defp names(servers), do: Enum.map_join(servers, ", ", & &1.name)

  defp no_local_message(servers) do
    "No server of your account answers on this network. Your account lists " <>
      "#{names(servers)}. Check that the server is on, and on the same network as this device."
  end

  defp waiting_message do
    case Server.pending_code() do
      nil -> "plex.tv has not seen the code yet. Type it in, and press again."
      code -> "plex.tv has not seen the code #{code} yet. Type it in, and press again."
    end
  end

  # A code lives for a few minutes, and plex.tv that no longer keeps it has forgotten
  # this one. A person then starts again, and no stale code stays on the page.
  defp forget_code do
    Server.forget_pending()

    {:error, "That code ran out of time. Press Link this account for a new one."}
  end

  # **A codec that the pipeline cannot read is one that the server converts.**
  # `PiFi.Plex.Fill` writes `:unknown` for such a track, and this is the one path of
  # this source that asks a server to do work. See `PiFi.Plex.Server.transcode_url/2`.
  defp playable(%{format: format} = item, link) when format in [nil, :unknown] do
    converted(item, link)
  end

  defp playable(%{source_key: nil} = item, _link), do: {:error, {:not_read_yet, item.title}}

  defp playable(item, link) do
    case Server.stream_url(item.source_key, link) do
      {:ok, uri} ->
        {:ok,
         %{
           uri: uri,
           headers: [],
           transport: :download,
           container: item.container_format || :none,
           format: item.format,
           live?: false,
           position_ms: 0,
           key: item.id,
           position_bytes: 0
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The master playlist names one variant, and `PiFi.Player.Hls` reads it and gives
  # the media playlist that the pipeline reads. The container and the codec come from
  # that answer and not from a guess here, in the way that a station of internet radio
  # gives them.
  #
  # **A converted track is live as far as the reader is concerned.** It has an end, so
  # `live?` stays false and a person reads a length and a progress, and it is not a file
  # on the card, so nothing skips inside it.
  defp converted(item, link) do
    with {:ok, url} <- Server.transcode_url(item.source_ref, link),
         {:ok, hls} <- Hls.resolve(url, Server.transcode_format()) do
      {:ok,
       %{
         uri: URI.to_string(hls.media_playlist_uri),
         headers: [],
         transport: :hls,
         container: hls.container,
         format: hls.format,
         live?: false,
         position_ms: 0,
         key: item.id,
         position_bytes: 0
       }}
    end
  end

  defp state_description do
    cond do
      Server.configured?() -> linked_description()
      Server.linked_to_account?() -> "Press Find my server to name the one that holds your music."
      is_nil(Server.pending_code()) -> "This device is not linked yet."
      true -> waiting_description()
    end
  end

  defp linked_description do
    "This device reads #{Server.server_name() || "your server"}. #{tracks(count())}. " <>
      "Leave this empty unless your account lists more than one server."
  end

  defp waiting_description do
    "This device is waiting. Type the code #{Server.pending_code()} at plex.tv/link, " <>
      "and press Finish linking."
  end

  defp count do
    Ash.count!(Ash.Query.filter(Item, source == ^@source and kind == :track))
  end

  defp tracks(1), do: "The library has 1 track"
  defp tracks(count), do: "The library has #{count} tracks"

  defp present(text) when is_binary(text) do
    case String.trim(text) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp present(_other), do: :error
end
