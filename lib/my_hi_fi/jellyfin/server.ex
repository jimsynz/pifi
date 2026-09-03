defmodule MyHiFi.Jellyfin.Server do
  @moduledoc """
  Reads one Jellyfin server.

  See <https://jellyfin.org>. A person runs the server themselves and names its
  address here, so this source reaches a machine of the household and no service on
  the internet. `MyHiFi.Settings` holds the address, the token and the identifier of
  the device, because a device has no environment to read a value from.

  ## The header that every request carries

  Jellyfin reads the client, the device and the token from one header.

      Authorization: MediaBrowser Client="MyHiFi", Device="<name>",
                     DeviceId="<id>", Version="<version>", Token="<token>"

  **`DeviceId` must stay the same for the life of the device.** The server lists one
  device for each identifier that it meets, so an identifier that changes at each
  boot fills that list. `device_id/0` makes one the first time and the settings hold
  it.

  ## Two ways to link, and Quick Connect is the first

  A person types a code of six characters into a Jellyfin client that they already
  use, and the server then gives an access token. No password reaches this device,
  and no person types a password on a screen of 320 by 240.

  Two answers of the server matter here. A server of an older version answers 405
  for `POST /QuickConnect/Initiate`, so `quick_connect/0` sends `GET` after that
  answer. An administrator can turn Quick Connect off, and the server then answers
  401.

  `authenticate_by_name/2` is the second way, for a server that turned Quick Connect
  off.

  ## The address of the audio, and why it names one container

  `stream_url/2` names the one container that the pipeline expects for that track,
  and not a list of three. **The player must know the codec before the first byte
  arrives**, because `MyHiFi.Player.Pipeline` builds a decoder from it. A list of
  three containers gives the server three answers to choose between, and this device
  cannot read that choice from a file that it has not yet begun.

  `MyHiFi.Jellyfin.Fill` therefore writes `format` of each track from the container
  that the server reports, and this names that same container back. A track of any
  other container becomes `:mp3`, and the server converts it. That covers ALAC, WAV,
  AIFF, WMA and Opus, and each of those is rare in a music library.

  **The token travels in the query and not in a header.**
  `MyHiFi.Player.Download` builds the headers of its own request, and it takes none
  from a caller. Jellyfin reads `api_key` from the query for this reason, and every
  Jellyfin client uses it for a direct address.
  """

  alias MyHiFi.Settings

  @address_setting "jellyfin_address"
  @code_setting "jellyfin_quick_connect_code"
  @device_id_setting "jellyfin_device_id"
  @secret_setting "jellyfin_quick_connect_secret"
  @token_setting "jellyfin_token"
  @user_setting "jellyfin_user_id"

  @client "MyHiFi"
  @version Mix.Project.config()[:version]

  # A page of 200 is one answer of about 200 KB, and a library of 40,000 tracks is
  # then 200 answers. A larger page holds more of the library in memory at one time,
  # and this board holds 363.9 MB.
  @page 200

  # The height of the artwork that the cache holds. The device screen is 320 by 240,
  # and the web interface draws a larger picture on a tablet.
  @artwork_height 600

  # A limit that no music file of a normal library passes, so a track converts for
  # its container and never for its bitrate. A low limit would convert every FLAC,
  # and this device reads over a local network where the bytes cost nothing.
  @max_bitrate 8_000_000

  @timeout :timer.seconds(30)

  @typedoc "One artist, one album or one track, in the shape that `MyHiFi.Jellyfin.Fill` takes."
  @type entry :: %{
          required(:ref) => String.t(),
          required(:title) => String.t(),
          optional(:parent_ref) => String.t() | nil,
          optional(:subtitle) => String.t() | nil,
          optional(:artwork_url) => String.t() | nil,
          optional(:duration_ms) => pos_integer() | nil,
          optional(:byte_size) => pos_integer() | nil,
          optional(:published_at) => DateTime.t() | nil,
          optional(:format) => :aac | :flac | :mp3
        }

  @typedoc """
  One page of a listing.

  `total` is how many entries the whole listing holds, and `count` is how many the
  server sent in this answer. The two are separate from `entries`, because an item
  that cannot become a row is absent there and a caller must still move the same
  distance through the listing.
  """
  @type page :: %{entries: [entry()], count: non_neg_integer(), total: non_neg_integer()}

  @doc "The settings key that holds the address of the server."
  @spec address_setting() :: String.t()
  def address_setting, do: @address_setting

  @doc "The settings key that holds the code that a person types into their client."
  @spec code_setting() :: String.t()
  def code_setting, do: @code_setting

  @doc "The settings key that holds the identifier of this device."
  @spec device_id_setting() :: String.t()
  def device_id_setting, do: @device_id_setting

  @doc "The settings key that holds the secret of a link that is not finished."
  @spec secret_setting() :: String.t()
  def secret_setting, do: @secret_setting

  @doc "The settings key that holds the access token."
  @spec token_setting() :: String.t()
  def token_setting, do: @token_setting

  @doc "The settings key that holds the identifier of the user."
  @spec user_setting() :: String.t()
  def user_setting, do: @user_setting

  @doc """
  The address of the server, with no separator at the end.

  It gives `{:error, :no_address}` for a device that holds none.
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

  A link needs the address, the token and the user, and a device that holds one of
  the three can reach nothing. `MyHiFi.AutoSync` asks this before it reads a
  library.
  """
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _link}, link())

  @doc """
  The identifier of this device, for the header of each request.

  It makes one the first time that something asks, and the settings then hold it for
  the life of the device. See the moduledoc.
  """
  @spec device_id() :: String.t()
  def device_id do
    case Settings.fetch(@device_id_setting) do
      {:ok, %{value: value}} ->
        value

      {:error, _reason} ->
        made = Ash.UUID.generate()
        Settings.put!(@device_id_setting, made)

        made
    end
  end

  @doc """
  The name that the server lists this device under.

  It is the host name of the board, so a household with two of them reads which is
  which. A host that answers no name gives `MyHiFi`.
  """
  @spec device_name() :: String.t()
  def device_name do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _other -> @client
    end
  end

  @doc """
  The `Authorization` header of one request.

  The token is absent for a request that needs none, such as the first step of Quick
  Connect.

      iex> header = authorization("SECRETTOKEN")
      iex> String.starts_with?(header, ~s(MediaBrowser Client="MyHiFi", Device="))
      true
      iex> String.ends_with?(header, ~s(, Token="SECRETTOKEN"))
      true
  """
  @spec authorization(String.t() | nil) :: String.t()
  def authorization(token \\ nil) do
    ~s(MediaBrowser Client="#{@client}", Device="#{device_name()}", ) <>
      ~s(DeviceId="#{device_id()}", Version="#{@version}", Token="#{token}")
  end

  @doc """
  Ask one address whether a Jellyfin server answers there.

  `put_settings/1` of the source calls this with what a person typed, so the address
  is not the one that the settings hold. It gives the name of the server, which is
  what tells a person that they typed the right thing.
  """
  @spec public_info(String.t()) ::
          {:ok, %{name: String.t(), version: String.t() | nil}} | {:error, term()}
  def public_info(address) do
    with {:ok, body} <- request(:get, address, nil, "/System/Info/Public", []) do
      {:ok, %{name: body["ServerName"] || "a Jellyfin server", version: body["Version"]}}
    end
  end

  @doc """
  Ask the server for a Quick Connect code.

  It gives the code that a person types into their client, and the secret that
  `quick_connect_state/1` and `authenticate_with_quick_connect/1` name.

  A server that turned Quick Connect off answers `{:error, :quick_connect_off}`.
  """
  @spec quick_connect() :: {:ok, %{secret: String.t(), code: String.t()}} | {:error, term()}
  def quick_connect do
    with {:ok, address} <- address(),
         {:ok, body} <- initiate(address) do
      case {body["Secret"], body["Code"]} do
        {secret, code} when is_binary(secret) and is_binary(code) ->
          {:ok, %{secret: secret, code: code}}

        _other ->
          {:error, :no_code}
      end
    end
  end

  @doc """
  Has a person typed the code into their client yet?

  It gives `{:ok, :authenticated}` when they have, and `{:ok, :waiting}` when they
  have not. A secret that the server does not hold any more gives
  `{:error, :unknown_secret}`, and a code that ran out of time is one of those.
  """
  @spec quick_connect_state(String.t()) ::
          {:ok, :authenticated | :waiting} | {:error, term()}
  def quick_connect_state(secret) do
    with {:ok, address} <- address(),
         {:ok, body} <- request(:get, address, nil, "/QuickConnect/Connect", secret: secret) do
      if body["Authenticated"] == true, do: {:ok, :authenticated}, else: {:ok, :waiting}
    else
      {:error, :not_found} -> {:error, :unknown_secret}
      other -> other
    end
  end

  @doc """
  Take the access token of a Quick Connect that a person finished.

  See `quick_connect_state/1`. It writes the token and the user into the settings,
  and it removes the secret and the code, so nothing waits for a link that is done.
  """
  @spec authenticate_with_quick_connect(String.t()) :: {:ok, String.t()} | {:error, term()}
  def authenticate_with_quick_connect(secret) do
    with {:ok, address} <- address(),
         {:ok, body} <-
           request(:post, address, nil, "/Users/AuthenticateWithQuickConnect", [],
             json: %{"Secret" => secret}
           ) do
      store_link(body)
    end
  end

  @doc """
  Take an access token with a user name and a password.

  This is the second way to link, for a server that turned Quick Connect off. It
  writes the token and the user into the settings.
  """
  @spec authenticate_by_name(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def authenticate_by_name(username, password) do
    with {:ok, address} <- address(),
         {:ok, body} <-
           request(:post, address, nil, "/Users/AuthenticateByName", [],
             json: %{"Username" => username, "Pw" => password}
           ) do
      store_link(body)
    end
  end

  @doc """
  Remove the link to the server.

  The address and the identifier of the device stay. A person who links again
  therefore types no address, and the server lists one device and not two.
  """
  @spec forget() :: :ok
  def forget do
    for key <- [@token_setting, @user_setting, @secret_setting, @code_setting] do
      case Settings.fetch(key) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end

    :ok
  end

  @doc """
  Read one page of the artists, of the albums, or of the tracks of the library.

  `start` is the number of entries to step over, and `page_size/0` gives how many
  each answer holds. The answer names how many the whole listing holds, so a caller
  reads pages until it has them all. See `MyHiFi.Jellyfin.Sync.Library`.
  """
  @spec page(:artists | :albums | :tracks, non_neg_integer()) :: {:ok, page()} | {:error, term()}
  def page(kind, start) do
    with {:ok, %{address: address, token: token, user_id: user_id}} <- link(),
         {:ok, body} <- request(:get, address, token, "/Items", params(kind, user_id, start)) do
      items = Map.get(body, "Items", [])

      {:ok,
       %{
         entries: parse(items, kind, address),
         count: length(items),
         total: Map.get(body, "TotalRecordCount", 0)
       }}
    end
  end

  @doc "How many entries one page of `page/2` holds."
  @spec page_size() :: pos_integer()
  def page_size, do: @page

  @doc """
  The address that plays one track.

  It names the container that `format` asks for, so the server sends the file as it
  is when the two agree and converts it when they do not. See the moduledoc.
  """
  @spec stream_url(String.t(), :aac | :flac | :mp3) :: {:ok, String.t()} | {:error, term()}
  def stream_url(ref, format) do
    with {:ok, %{address: address, token: token, user_id: user_id}} <- link() do
      query =
        [
          {"UserId", user_id},
          {"DeviceId", device_id()},
          {"container", container(format)},
          {"maxStreamingBitrate", @max_bitrate},
          {"api_key", token}
        ] ++ audio_codec(format)

      {:ok, "#{address}/Audio/#{ref}/universal?#{URI.encode_query(query)}"}
    end
  end

  @doc """
  Turn one artist of the server into the attributes of an item.

  It gives `nil` for an entry with no identifier and for one with no name, because
  neither one can become a row.
  """
  @spec artist(map(), String.t()) :: entry() | nil
  def artist(item, address), do: base(item, address)

  @doc """
  Turn one album of the server into the attributes of an item.

  `parent_ref` names the album artist. An album whose artist the server does not
  name holds `nil` there, and `MyHiFi.Jellyfin.Fill` writes it under the artist that
  it keeps for those.
  """
  @spec album(map(), String.t()) :: entry() | nil
  def album(item, address) do
    case base(item, address) do
      nil ->
        nil

      entry ->
        Map.merge(entry, %{
          parent_ref: album_artist_ref(item),
          subtitle: presence(item["AlbumArtist"]),
          published_at: published_at(item)
        })
    end
  end

  @doc """
  Turn one track of the server into the attributes of an item.

  `format` comes from the container that the server reports, and `stream_url/2`
  names that same container back. A container that this firmware does not decode
  becomes `:mp3`, and the server converts the file.
  """
  @spec track(map(), String.t()) :: entry() | nil
  def track(item, address) do
    case base(item, address) do
      nil ->
        nil

      entry ->
        Map.merge(entry, %{
          parent_ref: presence(item["AlbumId"]),
          subtitle: presence(item["Album"]) || presence(item["AlbumArtist"]),
          duration_ms: duration_ms(item["RunTimeTicks"]),
          byte_size: byte_size_of(item),
          published_at: published_at(item),
          format: format(item["Container"])
        })
    end
  end

  # An entry needs an identifier and a name, and an item of the server that holds
  # neither cannot become a row.
  defp base(item, address) when is_map(item) do
    with ref when is_binary(ref) <- presence(item["Id"]),
         title when is_binary(title) <- presence(item["Name"]) do
      %{ref: ref, title: title, parent_ref: nil, artwork_url: image(ref, item, address)}
    else
      _other -> nil
    end
  end

  defp base(_item, _address), do: nil

  defp store_link(body) do
    with token when is_binary(token) <- presence(body["AccessToken"]),
         user_id when is_binary(user_id) <- presence(get_in(body, ["User", "Id"])) do
      Settings.put!(@token_setting, token)
      Settings.put!(@user_setting, user_id)
      forget_quick_connect()

      {:ok, token}
    else
      _other -> {:error, :no_token}
    end
  end

  defp forget_quick_connect do
    for key <- [@secret_setting, @code_setting] do
      case Settings.fetch(key) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end
  end

  # A server of an older version answers 405 for the POST, and it takes a GET.
  defp initiate(address) do
    case request(:post, address, nil, "/QuickConnect/Initiate", []) do
      {:error, :method_not_allowed} -> request(:get, address, nil, "/QuickConnect/Initiate", [])
      {:error, :unauthorised} -> {:error, :quick_connect_off}
      other -> other
    end
  end

  defp link do
    with {:ok, address} <- address(),
         {:ok, %{value: token}} <- Settings.fetch(@token_setting),
         {:ok, %{value: user_id}} <- Settings.fetch(@user_setting) do
      {:ok, %{address: address, token: token, user_id: user_id}}
    else
      {:error, :no_address} -> {:error, :no_address}
      _other -> {:error, :not_linked}
    end
  end

  defp params(kind, user_id, start) do
    [
      {"UserId", user_id},
      {"IncludeItemTypes", item_type(kind)},
      {"Recursive", "true"},
      {"SortBy", "SortName"},
      {"SortOrder", "Ascending"},
      {"StartIndex", start},
      {"Limit", @page}
    ] ++ fields(kind)
  end

  defp item_type(:artists), do: "MusicArtist"
  defp item_type(:albums), do: "MusicAlbum"
  defp item_type(:tracks), do: "Audio"

  # `MediaSources` is the one place that the server names the size of a file, and
  # `MyHiFi.Playback.FavouriteAudio` reads that size before it asks for a track. It
  # makes a page of tracks larger, so no other listing asks for it.
  defp fields(:tracks), do: [{"Fields", "MediaSources"}]
  defp fields(_kind), do: []

  defp parse(items, kind, address) do
    reader = reader(kind)

    items
    |> Enum.map(&reader.(&1, address))
    |> Enum.reject(&is_nil/1)
  end

  defp reader(:artists), do: &artist/2
  defp reader(:albums), do: &album/2
  defp reader(:tracks), do: &track/2

  # An item with no picture of its own uses the picture of the container that holds
  # it, and the `artwork` calculation of `MyHiFi.Playback.Item` does that already.
  defp image(ref, %{"ImageTags" => %{"Primary" => _tag}}, address),
    do: "#{address}/Items/#{ref}/Images/Primary?maxHeight=#{@artwork_height}"

  defp image(_ref, _item, _address), do: nil

  defp album_artist_ref(item) do
    case item["AlbumArtists"] do
      [%{"Id" => ref} | _rest] -> presence(ref)
      _other -> nil
    end
  end

  # Jellyfin counts in ticks of 100 nanoseconds.
  defp duration_ms(ticks) when is_integer(ticks) and ticks > 0, do: div(ticks, 10_000)
  defp duration_ms(_ticks), do: nil

  # The first media source is the file that a play reads.
  # `MyHiFi.Playback.FavouriteAudio` reads this size before it asks for a track, and
  # it estimates one for a server that names none.
  defp byte_size_of(%{"MediaSources" => [%{"Size" => size} | _rest]})
       when is_integer(size) and size > 0,
       do: size

  defp byte_size_of(_item), do: nil

  defp published_at(item) do
    with date when is_binary(date) <- presence(item["PremiereDate"]),
         {:ok, at, _offset} <- DateTime.from_iso8601(date) do
      at
    else
      _other -> nil
    end
  end

  # The pipeline decodes these three as they are. Every other container becomes
  # `:mp3`, and `stream_url/2` then asks the server to convert the file.
  defp format("flac"), do: :flac
  defp format("mp3"), do: :mp3
  defp format("aac"), do: :aac
  defp format(_other), do: :mp3

  defp container(:flac), do: "flac"
  defp container(:aac), do: "aac"
  defp container(_format), do: "mp3"

  # `audioCodec` names what a conversion gives. FLAC and AAC reach this device as
  # they are, so naming a codec for them could only make the server do work that
  # nothing asked for.
  defp audio_codec(:mp3), do: [{"audioCodec", "mp3"}]
  defp audio_codec(_format), do: []

  # A test gives a stub with `config :my_hi_fi, MyHiFi.Jellyfin.Server, plug: ...`,
  # in the same way that `MyHiFi.Podcast.Index` takes one. Nothing sets this in
  # production.
  defp request(method, address, token, path, params, options \\ []) do
    [
      base_url: address,
      url: path,
      params: params,
      headers: [{"authorization", authorization(token)}, {"accept", "application/json"}],
      receive_timeout: @timeout,
      retry: :transient
    ]
    |> Keyword.merge(options)
    |> Keyword.merge(Application.get_env(:my_hi_fi, __MODULE__, []))
    |> Req.new()
    |> Req.request(method: method)
    |> answer()
  end

  defp answer({:ok, %{status: 200, body: body}}) when is_map(body), do: {:ok, body}
  defp answer({:ok, %{status: 204}}), do: {:ok, %{}}
  defp answer({:ok, %{status: 401}}), do: {:error, :unauthorised}
  defp answer({:ok, %{status: 404}}), do: {:error, :not_found}
  defp answer({:ok, %{status: 405}}), do: {:error, :method_not_allowed}
  defp answer({:ok, %{status: status}}), do: {:error, {:unexpected_status, status}}
  defp answer({:error, exception}), do: {:error, exception}

  defp presence(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_other), do: nil
end
