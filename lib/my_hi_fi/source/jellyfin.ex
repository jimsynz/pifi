defmodule MyHiFi.Source.Jellyfin do
  @moduledoc """
  The music library of one Jellyfin server, on the local network.

  The tree has three branches under the root.

      Artists             every artist of the library
        an artist         the albums of that artist
          an album        the tracks of that album
      Albums              every album of the library
      Favourites          the artists, the albums and the tracks that a person marked

  An artist and an album are containers, and a track plays. See
  `MyHiFi.Jellyfin.Fill` for the shape of the tree, and `MyHiFi.Jellyfin.Server` for
  the reads.

  ## It browses the catalogue and not the server

  `MyHiFi.Jellyfin.Sync` copies the library on to the card, so a person browses
  their music when the server is asleep and when the network is down. This is the
  shape that internet radio uses, and it is the reason that `opened/1` and
  `refresh/1` are absent: no branch of this source reaches the server, and there is
  nothing for either one to read.

  `resolve/1` is the one function that needs the server, and it needs it because the
  address of the audio carries the access token of the moment.

  ## Linking, and why a person presses twice

  Quick Connect is the way to link. The device asks for a code, a person types that
  code into a Jellyfin client that they already use, and the server then gives an
  access token. No password reaches this device.

  **The person says when they have typed the code, and no timer does.** A device
  cannot push a change to a settings page, so a poll behind the page would hold a
  job of the queue for the five minutes that a code lives and a person would still
  have to look again to see the answer. They press `Link this device`, they read the
  code in the description of the address, they type it, and they press
  `Finish linking`. The one who knows when the code went in is the one who typed it.

  A server that turned Quick Connect off takes a user name and a password instead.
  Both are fields of `settings/0`, and neither one is kept.

  ## A track keeps no place, and that decides what a mark reads

  A song is not an episode of a podcast. `MyHiFi.Jellyfin.Fill` therefore writes
  `keeps_place?` as false on each track, and `MyHiFi.Playback.Item` reads that when a
  person marks an album: it reads the audio of a track that keeps no place, and it
  leaves a subscribed show alone.
  """

  @behaviour MyHiFi.Source

  require Ash.Query

  alias MyHiFi.Jellyfin.Server
  alias MyHiFi.Jellyfin.Sync
  alias MyHiFi.Playback.Item
  alias MyHiFi.Settings

  @source "jellyfin"

  @impl MyHiFi.Source
  def title, do: "Jellyfin"

  # The mark of the service itself, and not the shelf that `:library` draws. A person
  # who reads the top row finds the service that they set up, by the mark that every
  # other Jellyfin client shows them. See `MyHiFiWeb.CoreComponents` and
  # `assets/vendor/brand.js`.
  @impl MyHiFi.Source
  def icon, do: :jellyfin

  # A song lasts three minutes, so no person moves inside one. `MyHiFi.Player.Skip`
  # reads MP3 frames as well, and this source gives FLAC and AAC, so a skip would
  # work for one track of a library and not for the next.
  #
  # A search is absent because the catalogue holds the whole library already, and
  # `MyHiFiWeb.SearchLive` needs a source to say so. That comes later.
  @impl MyHiFi.Source
  def capabilities, do: []

  @impl MyHiFi.Source
  def kinds, do: [container: "Albums", track: "Tracks"]

  @impl MyHiFi.Source
  def roots do
    [
      {"Artists", %{query: artists_query(), kind: :item}},
      {"Albums", %{query: albums_query(), kind: :item, facts: [:subtitle, :release_year]}},
      {"Favourites", %{query: favourites_query(), kind: :item, facts: [:subtitle, :release_year]}}
    ]
  end

  @doc """
  An album holds its tracks in the order that the record holds them.

  **The number decides, and not the date.** `PremiereDate` of a track is the date of
  the album, so every track of one carries the same value, and a list that sorted on it
  fell through to the alphabet: a person opening *The Bones of What You Believe* read
  "By The Throat" first and "Broken Bones" third from last.

  **The order is one column and not two.** `place` of the item holds the disc and the
  number as one number, because `Cinder.QueryBuilder` unsets the sort of a query when a
  person presses a sort control and applies the one column that they pressed: a sort of
  `[disc: :asc, number: :asc]` became `number` alone, and a set of two discs read 1-01,
  2-01, 1-02, 2-02. A server that names neither number leaves `place` absent, SQLite
  reads that as the smallest value, and the title then decides.

  An artist holds albums, and an album row shows its artist and its release year. An
  album holds tracks, and a track row shows its artist and its duration.
  """
  @impl MyHiFi.Source
  def listing(item) do
    %{
      number?: true,
      facts: listing_facts(item),
      sort: [place: :asc, title: :asc],
      order: {"Track", "place"}
    }
  end

  defp listing_facts(%{kind: :container, parent_id: nil}), do: [:subtitle, :release_year]
  defp listing_facts(_item), do: [:subtitle, :duration_ms]

  # An artist is the one container of this source with no parent, so this branch
  # needs no facet and no column of its own. See `MyHiFi.Jellyfin.Fill`.
  defp artists_query do
    Item
    |> Ash.Query.filter(source == ^@source and kind == :container and is_nil(parent_id))
    |> Ash.Query.sort(title: :asc)
  end

  defp albums_query do
    Item
    |> Ash.Query.filter(source == ^@source and kind == :container and not is_nil(parent_id))
    |> Ash.Query.sort(title: :asc)
  end

  defp favourites_query do
    Item
    |> Ash.Query.filter(source == ^@source and favourite? == true)
    |> Ash.Query.sort(title: :asc)
  end

  @impl MyHiFi.Source
  def resolve(%{kind: :track} = item), do: playable(item)

  def resolve(item), do: {:error, {:not_a_track, item.id}}

  # A device that holds no link reaches nothing, so `MyHiFi.AutoSync` writes no job
  # that can only fail.
  @impl MyHiFi.Source
  def ready?, do: Server.configured?()

  @impl MyHiFi.Source
  def settings do
    [
      %{
        key: "address",
        title: "Server address",
        description: state_description(),
        link: %{href: "https://jellyfin.org", title: "jellyfin.org"},
        type: :text,
        value: address_value(),
        write_only?: false
      },
      %{
        key: "username",
        title: "User name",
        description:
          "Give a name and a password only for a server that turned Quick Connect off. " <>
            "The device keeps neither one.",
        link: nil,
        type: :text,
        value: nil,
        write_only?: true
      },
      %{
        key: "password",
        title: "Password",
        description: nil,
        link: nil,
        type: :password,
        value: nil,
        write_only?: true
      }
    ]
  end

  @impl MyHiFi.Source
  def put_settings(%{"address" => address} = values) do
    with {:ok, address} <- normalise(address),
         {:ok, info} <- Server.public_info(address) do
      Settings.put!(Server.address_setting(), address)

      with_password(info, values)
    else
      :error ->
        {:error, "Give the address of your server, such as http://jellyfin.local:8096."}

      {:error, reason} ->
        {:error, "No Jellyfin server answered at that address: #{inspect(reason)}"}
    end
  end

  def put_settings(_values),
    do: {:error, "Give the address of your server, such as http://jellyfin.local:8096."}

  @impl MyHiFi.Source
  def settings_actions do
    cond do
      Server.configured?() -> [read_library(), remove_link()]
      not is_nil(pending_code()) -> [finish_link(), link()]
      true -> [link()]
    end
  end

  @impl MyHiFi.Source
  def run_settings_action("link") do
    case Server.quick_connect() do
      {:ok, %{secret: secret, code: code}} ->
        Settings.put!(Server.secret_setting(), secret)
        Settings.put!(Server.code_setting(), code)

        {:ok, "Type the code #{code} into your Jellyfin client, and then press Finish linking."}

      {:error, :quick_connect_off} ->
        {:error, "That server turned Quick Connect off. Give a user name and a password instead."}

      {:error, :no_address} ->
        {:error, "Give the address of your server first."}

      {:error, reason} ->
        {:error, "The server did not answer: #{inspect(reason)}"}
    end
  end

  def run_settings_action("finish_link") do
    case pending_secret() do
      nil -> {:error, "Press Link this device first."}
      secret -> finish(secret)
    end
  end

  def run_settings_action("read_library") do
    case MyHiFi.Source.ask_for_job(Sync, :sync_library) do
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

    {:ok, "The device holds no link. Your music stays in the list until the next read."}
  end

  def run_settings_action(_name), do: {:error, "Jellyfin holds no such control."}

  defp link do
    %{
      name: "link",
      title: "Link this device",
      description:
        "The device asks the server for a code. You then type that code into a Jellyfin " <>
          "client that you already use.",
      icon: :cloud
    }
  end

  defp finish_link do
    %{
      name: "finish_link",
      title: "Finish linking",
      description: "Press this after you type the code into your client.",
      icon: :refresh
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
      description: "The device forgets the token. The address stays.",
      icon: :remove
    }
  end

  defp finish(secret) do
    case Server.quick_connect_state(secret) do
      {:ok, :authenticated} -> take_token(secret)
      {:ok, :waiting} -> {:ok, waiting_message()}
      {:error, :unknown_secret} -> forget_code()
      {:error, reason} -> {:error, "The server did not answer: #{inspect(reason)}"}
    end
  end

  defp take_token(secret) do
    case Server.authenticate_with_quick_connect(secret) do
      {:ok, _token} ->
        {:ok, "The device is linked. It reads your library when the network answers."}

      {:error, reason} ->
        {:error, "The server gave no token: #{inspect(reason)}"}
    end
  end

  defp waiting_message do
    case pending_code() do
      nil -> "The server has not seen the code yet. Type it into your client, and press again."
      code -> "The server has not seen the code #{code} yet. Type it in, and press again."
    end
  end

  # A code lives for a few minutes, and a server that no longer holds the secret has
  # forgotten this one. A person then starts again, and no stale code stays on the
  # page.
  defp forget_code do
    Server.forget()

    {:error, "That code ran out of time. Press Link this device for a new one."}
  end

  defp with_password(info, %{"username" => username, "password" => password}) do
    case {present(username), present(password)} do
      {{:ok, username}, {:ok, password}} -> authenticate(info, username, password)
      _other -> {:ok, found(info)}
    end
  end

  defp with_password(info, _values), do: {:ok, found(info)}

  defp authenticate(info, username, password) do
    case Server.authenticate_by_name(username, password) do
      {:ok, _token} ->
        {:ok, "#{info.name} accepted that name. The device reads your library now."}

      {:error, :unauthorised} ->
        {:error, "#{info.name} refused that name and password."}

      {:error, reason} ->
        {:error, "#{info.name} gave no token: #{inspect(reason)}"}
    end
  end

  defp found(info), do: "#{info.name} answered. Press Link this device to finish."

  defp playable(%{format: nil} = item), do: {:error, {:not_read_yet, item.title}}

  defp playable(item) do
    case Server.stream_url(item.source_ref, item.format) do
      {:ok, uri} ->
        {:ok,
         %{
           uri: uri,
           headers: [],
           transport: :download,
           container: :none,
           format: item.format,
           live?: false,
           # A song keeps no place, so it plays from the start every time. See
           # `keeps_place?` of `MyHiFi.Playback.Item`.
           position_ms: 0,
           # `MyHiFi.Player.Download` holds the file under this name, and the
           # eviction of the cache reclaims a file that an older release wrote.
           key: item.id,
           position_bytes: 0
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp state_description do
    if Server.configured?() do
      "The device holds a link. #{tracks(count())}."
    else
      unlinked_description(Server.address(), pending_code())
    end
  end

  defp unlinked_description({:error, :no_address}, _code),
    do: "Give the address of your server, such as http://jellyfin.local:8096."

  defp unlinked_description({:ok, _address}, nil), do: "The device holds no link yet."

  defp unlinked_description({:ok, _address}, code) do
    "The device waits. Open Settings and then Quick Connect in a Jellyfin client " <>
      "that you already use, type the code #{code}, and press Finish linking."
  end

  defp address_value do
    case Server.address() do
      {:ok, address} -> address
      {:error, :no_address} -> nil
    end
  end

  defp pending_code do
    case Settings.fetch(Server.code_setting()) do
      {:ok, %{value: code}} -> code
      {:error, _reason} -> nil
    end
  end

  defp pending_secret do
    case Settings.fetch(Server.secret_setting()) do
      {:ok, %{value: secret}} -> secret
      {:error, _reason} -> nil
    end
  end

  defp count do
    Ash.count!(Ash.Query.filter(Item, source == ^@source and kind == :track))
  end

  defp tracks(1), do: "The library holds 1 track"
  defp tracks(count), do: "The library holds #{count} tracks"

  # A person may type a name with no scheme, and a browser takes one of those. The
  # address goes into a request, so it needs a scheme, and a separator at the end
  # would give a path with two of them.
  defp normalise(address) do
    case String.trim(address) do
      "" ->
        :error

      trimmed ->
        {:ok, trimmed |> with_scheme() |> String.trim_trailing("/")}
    end
  end

  defp with_scheme("http://" <> _rest = address), do: address
  defp with_scheme("https://" <> _rest = address), do: address
  defp with_scheme(address), do: "http://" <> address

  defp present(text) when is_binary(text) do
    case String.trim(text) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp present(_other), do: :error
end
