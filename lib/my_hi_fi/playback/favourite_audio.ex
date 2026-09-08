defmodule MyHiFi.Playback.FavouriteAudio do
  @moduledoc """
  Reads the audio of what a person marked on to the card.

  A person who marks an album hears it with no wait, and hears it when the server
  that holds it is off. The mark is the whole instruction: no person asks for a
  download, and no page holds a control for one.

  ## What reads, and what does not

  **A track whose `transport` is `:download`.** That fact of `MyHiFi.Playback.Item` is
  the rule, and nothing here names a source.

  - A radio station is a live stream. Its transport is `:http`, and a stream with no
    end holds nothing to read.
  - A song of a library reads from a file, so it reads, and a mark on the album that
    holds it reads every song of that album.
  - **An episode of a show reads, and a count holds it down.** A show holds hundreds of
    episodes and a feed grows every day, so a mark on one reads **the newest few that a
    person has not played**, and `c:MyHiFi.Source.hold_limit/0` is how many.
    `keeps_place?` said that an episode reads nothing at all before this, and a person
    who subscribed to a show then could not hear it away from the network.
  - A track that keeps its place and that a person marked by itself reads nothing. A
    person marks the show, and `MyHiFiWeb.ItemList.favourite/1` draws no control on an
    episode for that reason.

  **A mark reaches two levels.** An album holds tracks, so a mark on an album reads
  every one of them. An artist holds albums and no track of its own, so a mark on an
  artist reads the tracks of each album, one album after the other. A show holds
  episodes, so a mark on one reads the newest few of them. A discography is
  gigabytes, and **a person who marks one has said what they want the card for**: the
  three steps below stop the run at the first track that the card holds no room for,
  and the marks that a person put on most recently are the ones that the device holds.

  A run that reads album by album leaves whole albums on the card when it stops, and
  not one track of each.

  ## How much the card holds, in three steps

  1. **Read the track while the cache holds room for it.**
  2. **When it does not hold room, run the ordinary eviction, and name the room that
     this track needs.** That is `MyHiFi.Cache.prune/1` with `want_bytes`, and it
     takes the coldest entries that no `keep?` holds until the card holds that room.
     There is no eviction here, and there must not be: two rules for one card would
     fight each other. **The number matters.** An eviction with no target removes
     down to the limit alone, and a cache that is already inside its limit then loses
     nothing, so a track of 40 MB is refused beside gigabytes of cold artwork.
  3. **When the cache is still short of room, stop the run.** The card is full, and
     the marks that a person put on most recently are the ones that the device holds.

  **A run stops at the first track that does not fit, and it tries no smaller one.**
  This is what makes the run settle. A run that stepped over a large track and took a
  small one would leave room for the next run to read that large track again, and the
  device would write the card for ever.

  **The eviction of step 2 cannot take what this run has already written.** Each run
  gives the time that it started as the floor of the eviction, and an entry used at
  that time or after it stays. Without that floor the run removes its own work: a
  released track is an ordinary entry, so the coldest entry of a card that holds
  little else is the track that the same run read a moment ago. An album of twelve
  tracks then reads each one, removes it for the next one, and writes the card for
  ever. See the `:coldest` read of `MyHiFi.Cache.Entry`.

  `MyHiFi.Playback.Item` gives the marked items newest first, through the
  `favourited_at` attribute. That order is the whole of step 3: without it a full
  card holds an arbitrary set, and with it the card holds what a person chose last.

  ## The size of a track is a guard, and not an accounting

  The check reads `byte_size` of the item, which Jellyfin gives as
  `MediaSources[0].Size`. A source that cannot say leaves it absent, and the check
  then estimates the size from `duration_ms` at 1000 kbit/s, which is about a FLAC of
  16 bits at 44100 Hz. A track that says neither counts as 50 MB.

  Each estimate is larger than the file that it stands for, because the error that
  costs nothing is the one that stops a run early. The eviction is what keeps the
  card inside its limit, and `MyHiFi.Cache.prune/0` runs after each track arrives so
  that the next check reads the truth.

  ## The mark holds no file against an eviction

  `MyHiFi.Player.Download` writes each entry with `keep?`, which no eviction may
  take. That mark is right while the file grows and while a person plays it, and it
  is wrong for a file that only waits. **This therefore releases each entry as soon
  as its download is complete.** The cache then holds it by its last use, in the way
  that it holds every other entry.

  **`MyHiFi.Player.Download.ensure/2` gives two answers, and both of them release.**
  It answers that a file grows, and it answers that a file is already whole. The
  second answer comes when two runs ask for one track: the later caller joins the
  download of the first, and that download may end while it joins. A branch that
  released on the first answer alone held the file of such a track against every
  eviction, for ever, and no run after it read that file again to correct the mark.

  A newer favourite may therefore take the file of an older one, and the newest first
  order above is what makes that coherent. A favourite whose file went plays from the
  network, and that play writes it again through the ordinary path.

  **Nothing here touches an entry that the cache already holds.** `touch` moves the
  time that the eviction reads, so a run that touched every favourite would keep each
  one warm for ever and `keep?` would be back by another name.

  ## The work belongs to a job

  A person presses a control, and the control answers at once. `ask/1` puts a job in
  the queue, and `read/1` is what that job runs. See the `:cache_audio` trigger of
  `MyHiFi.Playback.Item`, and `MyHiFi.Jellyfin.Sync.Favourites` for the run that
  covers a device that held no network when the mark went on.
  """

  require Ash.Query
  require Logger

  alias MyHiFi.Cache
  alias MyHiFi.Jellyfin.Server
  alias MyHiFi.Playback.Item
  alias MyHiFi.Player.Download
  alias MyHiFi.Source

  # About a FLAC of 16 bits at 44100 Hz, which is the largest that a music library
  # holds. See the moduledoc for why every estimate here is generous.
  @estimated_bits_per_second 1_000_000

  # What a track counts as when it says neither its size nor its length.
  @unknown_bytes 50 * 1024 * 1024

  # A track of 40 MB over a local network takes seconds, and the same track over slow
  # Wi-Fi takes a minute. Ten minutes is longer than any one track, and it stops a
  # job that waits for a download that will never answer.
  @wait :timer.minutes(10)

  @doc """
  Ask for the audio of one item.

  It puts a job in the queue and answers at once, because a person pressed a
  control. A queue that refuses the job leaves the audio for the next run of
  `MyHiFi.Jellyfin.Sync.Favourites`, so this raises nothing.

  **An item that holds no audio to read asks for nothing.** A person who subscribes to
  a show marks a container of episodes, and an episode keeps its place, so
  `caches_audio?` is false for it. A job for such an item cancelled itself with
  `:trigger_no_longer_applies` when it ran, because AshOban reads the `where` of the
  trigger again at that moment. The work was correct and it read as a fault: a line of
  an error in the log and a cancelled job in the table for every subscription. The one
  read here costs a query on a control that already writes a row.
  """
  @spec ask(Item.t()) :: :ok
  def ask(item) do
    if holds_audio?(item), do: AshOban.run_trigger(item, :cache_audio)

    :ok
  rescue
    error ->
      Logger.warning("Could not ask for the audio of #{item.title}: #{inspect(error)}")

      :ok
  end

  @doc """
  Read the audio of one item, and give the number of tracks that the cache now holds.

  A track that the cache holds already reads nothing and it touches nothing. Every
  other one reads now, one at a time, so a marked album does not open twenty requests
  at once.

  It stops at the first track that the card holds no room for, and it counts the ones
  that arrived before that. See the moduledoc.

  **The link of a source that holds one is read once before the loop.** A source that
  needs credentials to build an address reads them here and not for each track, so a
  marked album of twelve tracks makes one read of the settings and not twelve.
  """
  @spec read(Item.t()) :: non_neg_integer()
  def read(item) do
    item
    |> tracks()
    |> hold_each(0, DateTime.utc_now(), source_links(item))
  end

  @doc """
  Let an eviction take the audio of one item.

  A person who removes a mark does not lose the file at once: the entry becomes an
  ordinary one, and the eviction takes it when the device needs the room. A person
  who changes their mind twice in a minute therefore reads the album one time.
  """
  @spec release(Item.t()) :: :ok
  def release(item) do
    item
    |> tracks()
    |> Enum.each(&Download.release(&1.id))
  end

  @doc """
  The tracks of one item whose audio this device can hold.

  A track gives itself, or nothing. A container gives the tracks that it holds, in
  the order that a person reads them on the page of that container. See the moduledoc
  for the rule.
  """
  @spec tracks(Item.t()) :: [Item.t()]
  def tracks(%{kind: :track} = item) do
    if holdable?(item), do: [item], else: []
  end

  def tracks(%{kind: :container} = item) do
    case songs_of(item) do
      [] -> episodes_or_below(item)
      songs -> songs
    end
  end

  # The calculation is the one rule, and this asks it about one item. A read that fails
  # gives `true`, so the job runs and the trigger of it decides: a queued job that
  # cancels itself is better than audio that a person marked and never got.
  defp holds_audio?(item) do
    case Ash.load(item, :caches_audio?) do
      {:ok, %{caches_audio?: holds?}} -> holds?
      {:error, _reason} -> true
    end
  end

  # A container that holds no song holds episodes or containers, and each of those
  # reads its own way.
  defp episodes_or_below(item) do
    case episodes_of(item) do
      [] -> item |> containers_of() |> Enum.flat_map(&tracks/1)
      episodes -> episodes
    end
  end

  # **Every song of the container, in the order of the record.** A person who marks an
  # album wants the record, so no count holds this down.
  defp songs_of(item) do
    Item
    |> Ash.Query.filter(
      parent_id == ^item.id and kind == :track and transport == :download and
        keeps_place? == false
    )
    |> Ash.Query.sort(place: :asc, title: :asc)
    |> Ash.read!()
  end

  # **The newest episodes that a person has not played, and no more than the source
  # holds.** A feed grows every day and a person wants the episode of this week, so a
  # count is what stops a subscription from filling the card. An episode that a person
  # played is one that they are done with, and the `:mark_played` action released its
  # file already.
  defp episodes_of(item) do
    query =
      Item
      |> Ash.Query.filter(
        parent_id == ^item.id and kind == :track and transport == :download and
          keeps_place? == true and played? == false
      )
      |> Ash.Query.sort(published_at: :desc, title: :asc)

    case hold_limit(item) do
      :all -> Ash.read!(query)
      limit -> query |> Ash.Query.limit(limit) |> Ash.read!()
    end
  end

  # **The item names its source, and the source names the count.** This module reads no
  # list of the sources: it asks whichever one holds the item, in the way that
  # `MyHiFiWeb.BrowseLive` asks for the order of a listing.
  defp hold_limit(item) do
    case Source.from_slug(item.source) do
      {:ok, module} -> Source.hold_limit(module)
      {:error, _reason} -> :all
    end
  end

  # **A container that holds no track of its own holds containers, and this reads
  # theirs.** An artist gives its albums, one after the other, and each album gives its
  # tracks in the order of the record. A run that stops half way through a discography
  # therefore holds whole albums and not a track from each of them.
  #
  # It reads one query for each album of a marked artist. That is five queries for the
  # artists of the measured library, and it happens when a person presses a control.
  defp containers_of(item) do
    Item
    |> Ash.Query.filter(parent_id == ^item.id and kind == :container)
    |> Ash.Query.sort(published_at: :asc, title: :asc)
    |> Ash.read!()
  end

  @doc """
  How many bytes one track needs of the card.

  It is the size that the source gave, or an estimate from the length of the track,
  or a fixed number for a track that says neither. See the moduledoc: this is a guard
  and not an accounting.
  """
  @spec size(Item.t()) :: pos_integer()
  def size(%{byte_size: bytes}) when is_integer(bytes) and bytes > 0, do: bytes

  def size(%{duration_ms: ms}) when is_integer(ms) and ms > 0,
    do: div(ms * @estimated_bits_per_second, 8000)

  def size(_track), do: @unknown_bytes

  defp holdable?(%{transport: :download, keeps_place?: false}), do: true
  defp holdable?(_item), do: false

  defp hold_each([], held, _started_at, _links), do: held

  defp hold_each([track | rest], held, started_at, links) do
    case hold(track, started_at, links) do
      :ok -> hold_each(rest, held + 1, started_at, links)
      :error -> hold_each(rest, held, started_at, links)
      :full -> held
    end
  end

  defp hold(track, started_at, links) do
    case Cache.fetch(Download.namespace(), track.id) do
      {:ok, _entry} -> :ok
      {:error, _reason} -> with_room(track, started_at, links)
    end
  end

  defp with_room(track, started_at, links) do
    bytes = size(track)

    if room?(bytes) or evicted?(bytes, started_at),
      do: start(track, started_at, links),
      else: full(track)
  end

  defp room?(bytes), do: bytes <= Cache.free_bytes()

  # The ordinary eviction of the cache, and no rule of its own. It takes the coldest
  # entries that no `keep?` holds, down to the room that this track needs, and this
  # then asks again.
  defp evicted?(bytes, started_at) do
    Cache.prune!(%{want_bytes: bytes, colder_than: started_at})

    room?(bytes)
  end

  defp start(track, started_at, links) do
    with {:ok, module} <- Source.from_slug(track.source),
         {:ok, %{transport: :download, key: key, uri: uri}} <- resolve(module, track, links),
         {:ok, %{complete?: complete?}} <- Download.ensure(key, uri) do
      if complete?, do: arrived(key, started_at), else: wait(key, track, started_at)
    else
      other -> failed(track, other)
    end
  end

  defp resolve(MyHiFi.Source.Jellyfin = module, track, links) do
    module.resolve(track, Map.get(links, module))
  end

  defp resolve(module, track, _links), do: module.resolve(track)

  defp source_links(item) do
    item
    |> tracks()
    |> Enum.map(& &1.source)
    |> Enum.uniq()
    |> Enum.reduce(%{}, &add_link/2)
  end

  defp add_link(slug, acc) do
    case Source.from_slug(slug) do
      {:ok, module} when module == MyHiFi.Source.Jellyfin ->
        case Server.link() do
          {:ok, link} -> Map.put(acc, module, link)
          {:error, _reason} -> acc
        end

      _other ->
        acc
    end
  end

  # The caller became a watcher of the download as `ensure/2` started it, so every
  # message of that download arrives here. See `MyHiFi.Player.Download`.
  defp wait(key, track, started_at) do
    receive do
      {:download, :done} ->
        arrived(key, started_at)

      {:download, {:error, reason}} ->
        failed(track, reason)

      {:download, {:bytes, _count}} ->
        wait(key, track, started_at)
    after
      @wait -> failed(track, :timeout)
    end
  end

  # The entry loses `keep?` as soon as the file is whole, and the eviction then holds
  # the total inside the limit, so the check of the next track reads the truth.
  defp arrived(key, started_at) do
    Download.release(key)
    Cache.prune!(%{colder_than: started_at})

    :ok
  end

  # A person marked more than the card holds. The device keeps what they marked most
  # recently, and the rest play from the network.
  defp full(track) do
    Logger.info("The card holds no room for #{track.title}, so this run stops here.")

    :full
  end

  # A track that did not arrive leaves the mark as it is. A person still hears it
  # from the network, and the next run reads it again.
  defp failed(track, reason) do
    Logger.warning("Could not hold the audio of #{track.title}: #{inspect(reason)}")

    :error
  end
end
