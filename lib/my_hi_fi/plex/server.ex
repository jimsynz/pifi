defmodule MyHiFi.Plex.Server do
  @moduledoc """
  Reads one Plex Media Server.

  See <https://www.plex.tv>. A person runs the server themselves, and this source
  reaches a machine of the household for every read of the library and every byte of
  audio. `MyHiFi.Settings` keeps the address, the tokens and the identifier of the
  client, because a device has no environment to read a value from.

  ## Two hosts, and only one of them is on the internet

  Plex is not Jellyfin in this one way: **a token can come from plex.tv and from
  nowhere else.** This module therefore speaks to two hosts.

  - `https://plex.tv` gives a code that a person types, and then an account token.
    `link_started/0`, `link_state/0` and `servers/0` are the three calls that reach
    it, and each one runs while a person is on the settings page.
  - The server of the household answers everything else. The library, the artwork
    and the audio never leave the local network.

  A device that is linked reaches plex.tv no more.

  ## The headers that every request carries

  Plex reads the client from a set of headers, and not from one.

      X-Plex-Client-Identifier: <id>
      X-Plex-Product: PiFi
      X-Plex-Version: <version>
      X-Plex-Device-Name: <name>
      X-Plex-Token: <token>

  **`X-Plex-Client-Identifier` must stay the same for the life of the device.** An
  account lists one device for each identifier that it meets, so an identifier that
  changes at each boot fills that list. `client_id/0` makes one the first time and
  the settings hold it.

  **`accept: application/json` is not optional.** A Plex server answers XML for a
  request that names no type, and every read of this module expects a map.

  ## A page is a header and not a parameter

  Jellyfin takes `StartIndex` and `Limit` in the query. Plex takes
  `X-Plex-Container-Start` and `X-Plex-Container-Size` as headers, and it answers
  with `size` and `totalSize` inside the `MediaContainer`. A caller therefore reads
  pages in the same way, and the request that asks for one differs.

  ## The server has a token of its own

  `/api/v2/resources` gives one entry for each server of the account, and each entry
  carries an `accessToken` that belongs to that server. **The account token is not
  what a server read uses.** `servers/0` reads both, and `use_server/1` keeps the one
  of the server that a person chose.

  Each entry also carries its connections, and one of those is on the local network.
  `local_connection/1` takes that one, so the device reads the household and never
  the relay of Plex.

  ## The address of the audio, and the codecs that a person hears

  Plex serves the file as it is. `Part.key` names the path of it, and the token goes
  in the query, so `stream_url/2` gives an address that reads the bytes that the disc
  of the server holds. Nothing converts, and the network of a household carries a
  FLAC without trouble.

  **The codec and the container are two facts, and the pipeline needs both.** MP3,
  FLAC, Vorbis in Ogg and AAC in ADTS all reach this device as the server holds them,
  and `MyHiFi.Plex.Fill` writes both from what the server reports.

  **Everything else is a conversion**, and `transcode_url/2` is the address of it. A
  sample of 550 tracks of one real library on 2026-09-14 gave 311 FLAC, 161 MP3 and 78
  AAC in MP4, so the conversion carries 14% of that library and a library of ALAC or
  WMA would lean on it further.
  """

  alias MyHiFi.Device.Identity
  alias MyHiFi.Settings

  @address_setting "plex_address"
  @client_id_setting "plex_client_id"
  @code_setting "plex_link_code"
  @pin_setting "plex_link_pin"
  @account_setting "plex_account_token"
  @machine_setting "plex_machine_id"
  @name_setting "plex_server_name"
  @token_setting "plex_token"

  @account "https://plex.tv"
  @product "PiFi"
  @version Mix.Project.config()[:version]

  # **A server converts for a platform that it holds a profile for.** `PiFi` is not one,
  # and a request that named it answered 400 with `unable to find a matching profile` in
  # the log of the server. This names no client that this firmware is not: the product
  # stays `PiFi`, and the platform says that the profile of a plain client will do.
  @platform "Generic"

  # **This names one codec, because a profile of two lets the server choose and a
  # caller cannot then say what it will read.** A profile of `aac,mp3` on a board on
  # 2026-09-14 gave MPEG-TS whose table named stream type 0x03, which is MP3, while the
  # pipeline had been told to expect AAC. The parser of AAC then read MP3 and gave no
  # sound and no error.
  #
  # MP3 is the one to name. `MyHiFi.Player.Pipeline` builds `:hls, :mpeg_ts, :mp3` for
  # 8 of the New Zealand stations already, and `MyHiFi.Player.MpegAudio` holds the one
  # trap of that path, so this reaches no new code at all.
  @transcode_profile "add-transcode-target(type=musicProfile&context=streaming&" <>
                       "protocol=hls&container=mpegts&audioCodec=mp3)"

  # What that profile gives. A master playlist of Plex names no `CODECS`, so
  # `MyHiFi.Player.Hls.resolve/2` takes this and the answer is not a guess.
  @transcode_format :mp3

  # **A conversion is the path of a track that this device cannot read as it is**, so
  # the loss of the codec is already paid and the bitrate should cost no more. 320 is
  # the largest that Plex offers for music.
  @transcode_bitrate "320"

  # **A page is the largest thing that a read of a library keeps at one time.** The
  # answer, the entries that `parse/2` builds from it, and the attribute maps that
  # `MyHiFi.Plex.Fill` builds from those all exist together, so this number decides the
  # memory of the whole read, on a board with 363.9 MB.
  #
  # 50 is the number that `MyHiFi.Jellyfin.Server` measured, and the two reads build the
  # same shapes from a page of the same size. Anybody who wants the read to finish
  # sooner should raise this, and watch what one page takes while they do.
  @page 50

  # The height of the artwork that the cache keeps. The device screen is 320 by 240,
  # and the web interface draws a larger picture on a tablet.
  @artwork_height 600

  @timeout :timer.seconds(30)

  # Plex names each kind of thing in a library by a number. A music section holds
  # these three.
  @artist_type 8
  @album_type 9
  @track_type 10

  @typedoc "One artist, one album or one track, in the shape that `MyHiFi.Plex.Fill` takes."
  @type entry :: %{
          required(:ref) => String.t(),
          required(:title) => String.t(),
          optional(:parent_ref) => String.t() | nil,
          optional(:subtitle) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:artwork_url) => String.t() | nil,
          optional(:duration_ms) => pos_integer() | nil,
          optional(:byte_size) => pos_integer() | nil,
          optional(:release_year) => pos_integer() | nil,
          optional(:added_at) => DateTime.t() | nil,
          optional(:number) => pos_integer() | nil,
          optional(:disc) => pos_integer() | nil,
          optional(:part_key) => String.t() | nil,
          optional(:format) => :aac | :flac | :mp3 | :vorbis | :unknown,
          optional(:container_format) => :none | :ogg,
          optional(:genres) => [String.t()]
        }

  @typedoc """
  One page of a listing.

  `total` is how many entries the whole listing has, and `count` is how many the
  server sent in this answer. The two are separate from `entries`, because an item
  that cannot become a row is absent there and a caller must still move the same
  distance through the listing.
  """
  @type page :: %{entries: [entry()], count: non_neg_integer(), total: non_neg_integer()}

  @typedoc "One server of the account, as `servers/0` reports it."
  @type resource :: %{
          name: String.t(),
          address: String.t() | nil,
          token: String.t()
        }

  @doc "The settings key of the address of the server."
  @spec address_setting() :: String.t()
  def address_setting, do: @address_setting

  @doc "The settings key of the token of the account."
  @spec account_setting() :: String.t()
  def account_setting, do: @account_setting

  @doc "The settings key of the identifier of this client."
  @spec client_id_setting() :: String.t()
  def client_id_setting, do: @client_id_setting

  @doc "The settings key of the code that a person types at plex.tv/link."
  @spec code_setting() :: String.t()
  def code_setting, do: @code_setting

  @doc "The settings key of the name of the server that a person chose."
  @spec name_setting() :: String.t()
  def name_setting, do: @name_setting

  @doc "The settings key of the identifier of a link that is not finished."
  @spec pin_setting() :: String.t()
  def pin_setting, do: @pin_setting

  @doc "The settings key of the access token of the server."
  @spec token_setting() :: String.t()
  def token_setting, do: @token_setting

  @doc """
  The address of the server, with no separator at the end.

  It returns `{:error, :no_address}` for a device that has chosen no server.
  """
  @spec address() :: {:ok, String.t()} | {:error, :no_address}
  def address do
    case Settings.fetch(@address_setting) do
      {:ok, %{value: value}} -> {:ok, value}
      {:error, _reason} -> {:error, :no_address}
    end
  end

  @doc """
  Does this device hold a link to a server?

  A link needs the address and the token of that server, and a device with one of the
  two can reach nothing. `MyHiFi.AutoSync` asks this before it reads a library.
  """
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _link}, link())

  @doc """
  Does this device hold a token of the account, and no server yet?

  A person who finished the code at plex.tv has this, and they still have to name
  which of their servers holds the music.
  """
  @spec linked_to_account?() :: boolean()
  def linked_to_account?, do: match?({:ok, _token}, account_token())

  @doc """
  The identifier of this client, for the headers of each request.

  It makes one the first time that something asks, and the settings then hold it for
  the life of the device. See the moduledoc.
  """
  @spec client_id() :: String.t()
  def client_id do
    case Settings.fetch(@client_id_setting) do
      {:ok, %{value: value}} ->
        value

      {:error, _reason} ->
        made = Ash.UUID.generate()
        Settings.put!(@client_id_setting, made)

        made
    end
  end

  @doc """
  What this device calls itself to Plex.

  `MyHiFi.Plex.Companion.Router` names these to a controller and the headers of each
  request name them to a server, so the three of them live here and in no other place.
  """
  @spec product() :: String.t()
  def product, do: @product

  @doc "The platform that this device names to Plex. See `product/0`."
  @spec platform() :: String.t()
  def platform, do: @platform

  @doc "The version of this firmware, as Plex reads it. See `product/0`."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  The name that the account lists this device under.

  It is the name that a person gave the device, so a household with two of them reads
  which is which. The session of the account does not move with it: `client_id/0` is
  what Plex keeps a device against, and that one never changes. See
  `MyHiFi.Device.Identity`.
  """
  @spec device_name() :: String.t()
  def device_name, do: Identity.name()

  @doc """
  The headers of one request.

  The token is absent for a request that needs none, such as the first step of the
  link. A caller that already read the identifier passes it as the second argument, so
  a loop of many requests makes one read of the settings and not one for each.

      iex> headers = headers("SECRETTOKEN", "THECLIENT")
      iex> headers["x-plex-token"]
      "SECRETTOKEN"
      iex> headers["x-plex-client-identifier"]
      "THECLIENT"
      iex> headers["x-plex-product"]
      "PiFi"
  """
  @spec headers(String.t() | nil, String.t() | nil) :: %{String.t() => String.t()}
  def headers(token \\ nil, client_id \\ nil) do
    %{
      "accept" => "application/json",
      "x-plex-client-identifier" => client_id || client_id(),
      "x-plex-device-name" => device_name(),
      "x-plex-product" => @product,
      "x-plex-token" => token || "",
      "x-plex-version" => @version
    }
  end

  @doc """
  Ask plex.tv for a code that a person types.

  It returns the code that they type at <https://plex.tv/link>, and the identifier
  that `link_state/0` names. The settings keep both, so the page can show the code
  again while a person walks to another screen.

  **This must not ask for a strong code.** The `strong` parameter of that endpoint
  decides which of two codes plex.tv makes. A strong one is long, and it belongs to
  the flow that sends a person to `app.plex.tv/auth` in a browser that the device
  drives. **plex.tv/link takes the short one, of four characters, and it takes no
  other.** A measurement on a board on 2026-09-14 asked for a strong code and told a
  person to type it at plex.tv/link, and that page has four boxes.
  """
  @spec start_link_to_account() ::
          {:ok, %{pin: String.t(), code: String.t()}} | {:error, term()}
  def start_link_to_account do
    with {:ok, body} <- request(:post, @account, nil, "/api/v2/pins", [], []) do
      case {body["id"], body["code"]} do
        {pin, code} when not is_nil(pin) and is_binary(code) ->
          pin = to_string(pin)
          Settings.put!(@pin_setting, pin)
          Settings.put!(@code_setting, code)

          {:ok, %{pin: pin, code: code}}

        _other ->
          {:error, :no_code}
      end
    end
  end

  @doc """
  Has a person typed the code at plex.tv yet?

  It returns `{:ok, :linked}` when they have, and the account token is then in the
  settings. It returns `{:ok, :waiting}` when they have not. A code that ran out of
  time gives `{:error, :unknown_pin}`.
  """
  @spec link_state() :: {:ok, :linked | :waiting} | {:error, term()}
  def link_state do
    with {:ok, pin} <- pending_pin(),
         {:ok, body} <- request(:get, @account, nil, "/api/v2/pins/#{pin}", [], []) do
      take_account_token(body["authToken"])
    else
      {:error, :not_found} -> {:error, :unknown_pin}
      other -> other
    end
  end

  @doc """
  Every server of the account that holds a local address.

  `use_server/1` takes one of these. A server with no local connection is absent,
  because this device reads the household and never the relay of Plex.
  """
  @spec servers() :: {:ok, [resource()]} | {:error, term()}
  def servers do
    with {:ok, token} <- account_token(),
         {:ok, body} <-
           request(:get, @account, token, "/api/v2/resources", [{"includeHttps", "1"}], []) do
      {:ok, body |> List.wrap() |> Enum.map(&resource/1) |> Enum.reject(&is_nil/1)}
    end
  end

  @doc """
  Keep one server of `servers/0`, so every later read names it.

  It writes the address, the token of that server and its name. A person with one
  server never chooses, and a household with two names the one that holds the music.
  """
  @spec use_server(resource()) :: :ok
  def use_server(%{name: name, address: address, token: token}) do
    Settings.put!(@address_setting, address)
    Settings.put!(@token_setting, token)
    Settings.put!(@name_setting, name)

    :ok
  end

  @doc """
  Remove the link to Plex.

  Both tokens go, and so does the address. The identifier of the client stays, so a
  person who links again lists one device and not two.
  """
  @spec forget() :: :ok
  def forget do
    for key <- [@account_setting, @token_setting, @address_setting, @name_setting] do
      forget_setting(key)
    end

    forget_pending()
  end

  @doc """
  Take the code away, because the link is done or a person started again.
  """
  @spec forget_pending() :: :ok
  def forget_pending do
    for key <- [@pin_setting, @code_setting], do: forget_setting(key)

    :ok
  end

  @doc """
  Take the name of the chosen server away.

  A person who clears `Server name` asks for the first server of the account that
  answers here, and that is what a device with no name does. **An empty setting is not
  the same as no setting**: `MyHiFi.Settings` takes no empty value, so this removes the
  row.
  """
  @spec forget_server_name() :: :ok
  def forget_server_name, do: forget_setting(@name_setting)

  @doc """
  Every music library of the server, in the order that the server lists them.

  A Plex server holds a section for each library, and a music one is a section of
  artists. A server with none gives an empty list, and `MyHiFi.Plex.Sync.Library`
  then writes nothing.
  """
  @spec sections(map() | nil) :: {:ok, [String.t()]} | {:error, term()}
  def sections(link \\ nil)

  def sections(nil) do
    with {:ok, link} <- link(), do: sections(link)
  end

  def sections(%{address: address, token: token, client_id: client_id}) do
    with {:ok, body} <-
           request(:get, address, token, "/library/sections", [], [], client_id) do
      keys =
        body
        |> container()
        |> Map.get("Directory", [])
        |> List.wrap()
        |> Enum.filter(&(&1["type"] == "artist"))
        |> Enum.map(& &1["key"])
        |> Enum.filter(&is_binary/1)

      {:ok, keys}
    end
  end

  @doc """
  Read one page of the artists, of the albums, or of the tracks of one section.

  `start` is the number of entries to step over, and `page_size/0` gives how many
  each answer carries. The answer says how many the whole listing has, so a caller
  reads pages until it has them all. See `MyHiFi.Plex.Sync.Library`.

  A caller that read the link already passes it as the fourth argument, so a loop of
  many pages makes one read of the settings and not three for each one.
  """
  @spec page(:artists | :albums | :tracks, String.t(), non_neg_integer(), map() | nil) ::
          {:ok, page()} | {:error, term()}
  def page(kind, section, start, link \\ nil)

  def page(kind, section, start, nil) do
    with {:ok, link} <- link(), do: page(kind, section, start, link)
  end

  def page(kind, section, start, %{address: address, token: token, client_id: client_id}) do
    paging = [
      {"x-plex-container-start", to_string(start)},
      {"x-plex-container-size", to_string(@page)}
    ]

    with {:ok, body} <-
           request(
             :get,
             address,
             token,
             "/library/sections/#{section}/all",
             [{"type", item_type(kind)}],
             paging,
             client_id
           ) do
      container = container(body)
      items = container |> Map.get("Metadata", []) |> List.wrap()

      {:ok,
       %{
         entries: parse(items, kind, address, token),
         count: length(items),
         total: total(container, items)
       }}
    end
  end

  @doc "How many entries one page of `page/4` carries."
  @spec page_size() :: pos_integer()
  def page_size, do: @page

  @doc """
  The address that plays one track.

  Plex serves the file as it is, so this names the part that the server reported and
  puts the token in the query. See the moduledoc for the codecs that this reaches.

  A caller that read the link already passes it as the second argument, so a loop of
  many tracks makes one read of the settings and not three for each one.
  """
  @spec stream_url(String.t(), map() | nil) :: {:ok, String.t()} | {:error, term()}
  def stream_url(part_key, link \\ nil)

  def stream_url(part_key, nil) do
    with {:ok, link} <- link(), do: stream_url(part_key, link)
  end

  def stream_url(part_key, %{address: address, token: token}) when is_binary(part_key) do
    {:ok, "#{address}#{part_key}?#{URI.encode_query([{"X-Plex-Token", token}])}"}
  end

  def stream_url(_part_key, _link), do: {:error, :no_part}

  @doc """
  The address of a playlist that converts one track to something this device reads.

  **Plex converts for a client that it holds a profile for, and for no other.** A
  request that named `PiFi` as its platform answered 400 and wrote
  `TranscodeUniversalRequest: unable to find a matching profile` into the log of the
  server. `Generic` is a platform that every Plex server holds a profile for, and
  `X-Plex-Product` stays `PiFi`, so the account still lists this device by its name.

  The answer is a master playlist of one variant, and that variant names segments of
  MPEG-TS that carry MP3. `MyHiFi.Player.Hls` reads the master and gives the media
  playlist, and `MyHiFi.Player.Pipeline` already builds `:hls, :mpeg_ts, :mp3` for 8 of
  the New Zealand stations.

  **Every value is in the query, and no header takes part.** A measurement on a board
  on 2026-09-14 gave 200 for that, which is what lets `MyHiFi.Player.Hls.resolve/2`
  read the address with no knowledge of Plex. The segments need no token at all: the
  identifier of the session in their path is what admits them.

  `session` is new for each call, because a server counts one conversion for each of
  them and a repeated identifier would join a stream that another play is reading.
  """
  @spec transcode_url(String.t(), map() | nil) :: {:ok, String.t()} | {:error, term()}
  def transcode_url(ref, link \\ nil)

  def transcode_url(ref, nil) do
    with {:ok, link} <- link(), do: transcode_url(ref, link)
  end

  def transcode_url(ref, %{address: address, token: token, client_id: client_id}) do
    query =
      URI.encode_query([
        {"path", "/library/metadata/#{ref}"},
        {"protocol", "hls"},
        {"session", Ash.UUID.generate()},
        {"musicBitrate", @transcode_bitrate},
        {"directPlay", "0"},
        {"directStream", "0"},
        {"hasMDE", "1"},
        {"X-Plex-Token", token},
        {"X-Plex-Client-Identifier", client_id},
        {"X-Plex-Product", @product},
        {"X-Plex-Version", @version},
        {"X-Plex-Platform", @platform},
        {"X-Plex-Client-Profile-Extra", @transcode_profile}
      ])

    {:ok, "#{address}/music/:/transcode/universal/start.m3u8?#{query}"}
  end

  @doc """
  The codec that a conversion gives.

  **A master playlist of Plex names no `CODECS`**, so `MyHiFi.Player.Hls.resolve/2`
  cannot read it from the playlist and takes this instead. It is a fact of
  `@transcode_profile` above and not a guess.
  """
  @spec transcode_format() :: :mp3
  def transcode_format, do: @transcode_format

  @doc """
  Turn one artist of the server into the attributes of an item.

  It returns `nil` for an entry with no identifier and for one with no name, because
  neither one can become a row.
  """
  @spec artist(map(), String.t(), String.t()) :: entry() | nil
  def artist(item, address, token), do: base(item, address, token)

  @doc """
  Turn one album of the server into the attributes of an item.

  `parent_ref` names the artist of the record. An album whose artist the server does
  not name gives `nil` there, and `MyHiFi.Plex.Fill` writes it under the artist that
  it keeps for those.
  """
  @spec album(map(), String.t(), String.t()) :: entry() | nil
  def album(item, address, token) do
    case base(item, address, token) do
      nil ->
        nil

      entry ->
        Map.merge(entry, %{
          parent_ref: presence(ref_of(item["parentRatingKey"])),
          subtitle: presence(item["parentTitle"]),
          release_year: whole(item["year"]),
          added_at: added_at(item["addedAt"]),
          genres: genres(item)
        })
    end
  end

  # **The genres arrive with the album, and this asks the server for nothing more.** A
  # read of a real library on 2026-09-14 gave `"Genre" => [%{"tag" => "Rap"}]` in the
  # answer that the sync already reads, so a genre costs no request of its own.
  defp genres(item) do
    item
    |> Map.get("Genre", [])
    |> List.wrap()
    |> Enum.map(&presence(&1["tag"]))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Turn one track of the server into the attributes of an item.

  `subtitle` names the artist. **The album says nothing that a person needs there.** A
  person inside an album reads the name of that album at the head of the list, and a
  person at the now playing screen of the device reads the title of the track and one
  line under it. That line must name who plays.

  `parent_ref` names the album, which Plex calls the parent. `grandparentRatingKey`
  names the artist, and no track needs it: an album already names that artist, so the
  tree reaches it in one more step.

  `part_key` is the path of the file, and `stream_url/2` builds the address from it. A
  track with no part cannot play, and `MyHiFi.Source.Plex.resolve/1` says so.
  """
  @spec track(map(), String.t(), String.t()) :: entry() | nil
  def track(item, address, token) do
    case base(item, address, token) do
      nil ->
        nil

      entry ->
        media = first_media(item)
        part = first_part(media)

        Map.merge(entry, %{
          parent_ref: presence(ref_of(item["parentRatingKey"])),
          subtitle: presence(item["grandparentTitle"]),
          duration_ms: whole(item["duration"]),
          byte_size: whole(part["size"]),
          number: whole(item["index"]),
          disc: whole(item["parentIndex"]),
          part_key: presence(part["key"]),
          format: format(media["audioCodec"], media["container"]),
          container_format: container_format(media["container"])
        })
    end
  end

  @doc """
  The address, the token and the identifier of the client, in one read.

  A caller that needs all three reads them once and passes them on, so a loop of many
  pages makes one read and not three for each one. See `MyHiFi.Plex.Sync.Library`.

  It returns `{:error, :no_address}` for a device that chose no server, and
  `{:error, :not_linked}` for one with no token of that server.
  """
  @spec link() ::
          {:ok, %{address: String.t(), token: String.t(), client_id: String.t()}}
          | {:error, :no_address | :not_linked}
  def link do
    with {:ok, address} <- address(),
         {:ok, %{value: token}} <- Settings.fetch(@token_setting) do
      {:ok, %{address: address, token: token, client_id: client_id()}}
    else
      {:error, :no_address} -> {:error, :no_address}
      _other -> {:error, :not_linked}
    end
  end

  @doc """
  The identifier that the server calls itself by.

  **This is not `client_id/0`.** That one names this device, and this one names the
  machine that holds the music. A controller reads it from the timeline of a player,
  beside the address and the port, so that it knows where to ask for the artwork of
  the track that plays. A measurement against a real player on 2026-09-15 gave the
  same value in both places.

  The server answers `/identity` with it, and that endpoint needs no token. The
  settings keep the answer, because a controller reads a timeline again and again and
  the identifier of a machine does not move.
  """
  @spec machine_id() :: {:ok, String.t()} | {:error, term()}
  def machine_id do
    case Settings.fetch(@machine_setting) do
      {:ok, %{value: value}} -> {:ok, value}
      {:error, _reason} -> read_machine_id()
    end
  end

  defp read_machine_id do
    with {:ok, %{address: address, token: token, client_id: client_id}} <- link(),
         {:ok, body} <- request(:get, address, token, "/identity", [], [], client_id),
         id when is_binary(id) <- container(body)["machineIdentifier"] do
      Settings.put!(@machine_setting, id)

      {:ok, id}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :no_machine_id}
    end
  end

  @doc """
  The token of the account, which plex.tv gave.

  It returns `{:error, :not_linked}` for a device that has not finished the code.
  """
  @spec account_token() :: {:ok, String.t()} | {:error, :not_linked}
  def account_token do
    case Settings.fetch(@account_setting) do
      {:ok, %{value: value}} -> {:ok, value}
      {:error, _reason} -> {:error, :not_linked}
    end
  end

  @doc "The code that a person types at plex.tv, or `nil` for a device with none."
  @spec pending_code() :: String.t() | nil
  def pending_code do
    case Settings.fetch(@code_setting) do
      {:ok, %{value: code}} -> code
      {:error, _reason} -> nil
    end
  end

  @doc "The name of the server that a person chose, or `nil` for a device with none."
  @spec server_name() :: String.t() | nil
  def server_name do
    case Settings.fetch(@name_setting) do
      {:ok, %{value: name}} -> name
      {:error, _reason} -> nil
    end
  end

  # An entry needs an identifier and a name, and an item of the server that gives
  # neither cannot become a row.
  # **`summary` is what a person reads about an artist and about a record**, and Plex
  # gives it in the listing, so no read of its own is needed. A sample of 150 albums of
  # one real library on 2026-09-14 held 111 of them, of 1,267 bytes on average and
  # 3,669 at the largest.
  #
  # It is read here, for every kind, because a track that carries one is then written
  # as well and a track that carries none writes nothing. A music library holds almost
  # none on a track.
  defp base(item, address, token) when is_map(item) do
    with ref when is_binary(ref) <- presence(ref_of(item["ratingKey"])),
         title when is_binary(title) <- presence(item["title"]) do
      %{
        ref: ref,
        title: title,
        parent_ref: nil,
        description: presence(item["summary"]),
        artwork_url: image(item, address, token)
      }
    else
      _other -> nil
    end
  end

  defp base(_item, _address, _token), do: nil

  # **Plex gives a rating key as a number in some answers and as text in others.** A
  # `parentRatingKey` that read as 1965 and a `ratingKey` that read as "1965" would
  # name one album twice, and the tree would lose every track of it.
  defp ref_of(nil), do: nil
  defp ref_of(ref) when is_binary(ref), do: ref
  defp ref_of(ref) when is_integer(ref), do: Integer.to_string(ref)
  defp ref_of(_other), do: nil

  defp take_account_token(token) when is_binary(token) and token != "" do
    Settings.put!(@account_setting, token)
    forget_pending()

    {:ok, :linked}
  end

  defp take_account_token(_token), do: {:ok, :waiting}

  defp pending_pin do
    case Settings.fetch(@pin_setting) do
      {:ok, %{value: pin}} -> {:ok, pin}
      {:error, _reason} -> {:error, :no_pin}
    end
  end

  defp forget_setting(key) do
    case Settings.fetch(key) do
      {:ok, setting} -> Settings.delete!(setting)
      {:error, _reason} -> :ok
    end

    :ok
  end

  # One entry of `/api/v2/resources`. A resource that is not a server is absent, and so
  # is one that no local connection reaches.
  defp resource(%{"provides" => provides} = entry) when is_binary(provides) do
    if "server" in String.split(provides, ",") do
      built(entry)
    else
      nil
    end
  end

  defp resource(_entry), do: nil

  defp built(entry) do
    with name when is_binary(name) <- presence(entry["name"]),
         token when is_binary(token) <- presence(entry["accessToken"]) do
      %{name: name, address: local_connection(entry), token: token}
    else
      _other -> nil
    end
  end

  # **The local connection is the one that this device wants.** A resource carries
  # several, and one of them is the relay of Plex, which carries the audio of a
  # household over the internet and back. `local` says which is which.
  defp local_connection(entry) do
    entry
    |> Map.get("connections", [])
    |> List.wrap()
    |> Enum.filter(&(&1["local"] == true))
    |> Enum.map(& &1["uri"])
    |> Enum.find(&is_binary/1)
  end

  defp item_type(:artists), do: @artist_type
  defp item_type(:albums), do: @album_type
  defp item_type(:tracks), do: @track_type

  defp container(body) when is_map(body), do: Map.get(body, "MediaContainer", %{})
  defp container(_body), do: %{}

  # **A `MediaContainer` names `totalSize` only when it has more than one page.** A
  # section of 12 albums answers with `size` and no `totalSize`, and a caller that read
  # zero there would stop before it wrote a row.
  defp total(container, items) do
    case whole(container["totalSize"]) do
      nil -> length(items)
      total -> total
    end
  end

  defp parse(items, kind, address, token) do
    reader = reader(kind)

    items
    |> Enum.map(&reader.(&1, address, token))
    |> Enum.reject(&is_nil/1)
  end

  defp reader(:artists), do: &artist/3
  defp reader(:albums), do: &album/3
  defp reader(:tracks), do: &track/3

  # An item with no picture of its own uses the picture of the container above it, and
  # the `artwork` calculation of `MyHiFi.Playback.Item` does that already.
  #
  # The server draws the size that this asks for, so the cache keeps one picture and
  # not the 2000 pixel original of a record sleeve.
  #
  # **The token belongs in this address, and Jellyfin is what made that easy to miss.**
  # A Jellyfin server draws a picture for a request that carries nothing, and a Plex
  # server answers 401. A read of a real library on 2026-09-14 therefore wrote 63,010
  # tracks with an address that no picture came back from, and every row of every list
  # drew the mark that `MyHiFi.Artwork` draws for a picture it does not hold.
  #
  # **This costs a read of the artwork again when a person links the device again.**
  # `MyHiFi.Artwork` keeps each picture under the SHA-256 of its address, so a new
  # token is a new address and no cached picture answers it. `artwork_url` is one of
  # the `upsert_fields` of `MyHiFi.Plex.Fill`, so the next read of the library writes
  # the new address and the pictures arrive again over the local network. A link again
  # is a rare thing, and the alternative is for `MyHiFi.Artwork` to hold knowledge of
  # Plex, which would put one service into the module that serves every source.
  defp image(item, address, token) do
    case presence(item["thumb"]) do
      nil ->
        nil

      thumb ->
        query =
          URI.encode_query([
            {"width", @artwork_height},
            {"height", @artwork_height},
            {"minSize", 1},
            {"url", thumb},
            {"X-Plex-Token", token}
          ])

        "#{address}/photo/:/transcode?#{query}"
    end
  end

  defp first_media(item) do
    case item["Media"] do
      [media | _rest] when is_map(media) -> media
      _other -> %{}
    end
  end

  defp first_part(media) do
    case media["Part"] do
      [part | _rest] when is_map(part) -> part
      _other -> %{}
    end
  end

  # **The pipeline reads these four and no other.** See the moduledoc for what a track
  # of any other codec does, and for what a conversion would need.
  #
  # A container of `ogg` decides nothing by itself: Ogg carries Vorbis and it carries
  # FLAC, and `container_format/1` names the wrapper while this names what is inside
  # it.
  #
  # **AAC in MP4 is a conversion and not a read.** The frames of an m4a file sit in a
  # table and not in the bytes, and `Membrane.MP4.Demuxer.ISOM` reads that table for a
  # file that it can parse. Two boxes of an ordinary m4a defeat it, one after the other,
  # and each is a gap in a schema that names its boxes by where they sit. The server
  # converts such a file instead, which is one path for every codec that this firmware
  # cannot read and no path that a new kind of file can break.
  #
  # AAC in ADTS has no such table and the decoder reads it as it is.
  defp format("flac", _container), do: :flac
  defp format("mp3", _container), do: :mp3
  defp format("vorbis", _container), do: :vorbis
  defp format("aac", container) when container in ["aac", "adts"], do: :aac
  defp format(_codec, _container), do: :unknown

  defp container_format("ogg"), do: :ogg
  defp container_format(_other), do: :none

  # Plex counts in whole milliseconds, and it gives a number as text in some answers.
  defp whole(number) when is_integer(number) and number > 0, do: number

  defp whole(text) when is_binary(text) do
    case Integer.parse(text) do
      {number, _rest} when number > 0 -> number
      _other -> nil
    end
  end

  defp whole(_other), do: nil

  # **`addedAt` is when the server first held the album, and it is not the release
  # date.** `year` is the release, and `MyHiFi.Playback.Item` keeps that under
  # `release_year`. A person who wants the record that they added last week needs the
  # first one, and a record of 1979 that they added last week gives the two 47 years
  # apart.
  #
  # Plex counts it in whole seconds from the epoch.
  defp added_at(seconds) do
    case whole(seconds) do
      nil -> nil
      seconds -> DateTime.from_unix!(seconds)
    end
  end

  defp presence(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_other), do: nil

  # A test gives a stub with `config :my_hi_fi, MyHiFi.Plex.Server, plug: ...`, in the
  # same way that `MyHiFi.Jellyfin.Server` takes one. Nothing sets this in production.
  defp request(method, address, token, path, params, extra_headers, client_id \\ nil) do
    headers =
      token
      |> headers(client_id)
      |> Map.to_list()
      |> Kernel.++(extra_headers)

    [
      base_url: address,
      url: path,
      params: params,
      headers: headers,
      receive_timeout: @timeout,
      retry: :transient
    ]
    |> Keyword.merge(Application.get_env(:my_hi_fi, __MODULE__, []))
    |> Req.new()
    |> Req.request(method: method)
    |> answer()
  end

  defp answer({:ok, %{status: status, body: body}}) when status in [200, 201] and is_map(body),
    do: {:ok, body}

  defp answer({:ok, %{status: status, body: body}}) when status in [200, 201] and is_list(body),
    do: {:ok, body}

  defp answer({:ok, %{status: 204}}), do: {:ok, %{}}
  defp answer({:ok, %{status: status}}) when status in [401, 403], do: {:error, :unauthorised}
  defp answer({:ok, %{status: 404}}), do: {:error, :not_found}
  defp answer({:ok, %{status: status}}), do: {:error, {:unexpected_status, status}}
  defp answer({:error, exception}), do: {:error, exception}
end
