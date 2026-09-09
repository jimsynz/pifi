defmodule MyHiFi.Artwork do
  @moduledoc """
  The local copy of a picture that a service names with an address.

  A station names its logo, and a podcast names the cover of a show and the picture
  of an episode. The web interface serves the copy instead, for two reasons. A page
  then shows a picture when the internet is not there, and the content security
  policy of the device holds `'self'` alone, so no page asks another server for
  anything.

  `MyHiFi.Cache` holds the file and the row, in the namespace `"artwork"`. This module
  holds what a cache cannot know:

  - The four types that this firmware serves, and the reason that SVG is absent. An
    SVG file holds a script, and the device serves each file from its own address, so
    such a script would run with the rights of the web interface.
  - The read of the first bytes, because a `content-type` header is often wrong.
  - The 4 MB limit for one picture.

  The name of an entry is a hash of the address, and it carries no extension. The
  type lives on the row, so serving one picture reads one row and the name needs no
  guess about which of four files exists.

  **A person also gives a picture, and it lives here too.** The splash of the device
  screen comes from a browser and not from a service, so `put/1` names it by the hash
  of the bytes. That name holds 64 characters like the hash of an address, and every
  reader of this module therefore takes it. See `MyHiFi.Device.Identity`.
  """

  alias MyHiFi.Artwork.Accent
  alias MyHiFi.Artwork.Thumbnail
  alias MyHiFi.Cache

  # Sobelow reads `@sobelow_skip` from the source. This registration stops the
  # compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @namespace "artwork"

  # This firmware stores one of these, and it serves what it stored. A type that is
  # absent here never reaches the disk.
  #
  # SVG is absent on purpose. See the module documentation.
  @content_types %{
    "png" => "image/png",
    "jpg" => "image/jpeg",
    "gif" => "image/gif",
    "webp" => "image/webp"
  }

  @served_types Map.values(@content_types)

  # A logo of a station is small, and a cover of a podcast is 1.2 MB. 4 MB holds
  # either one and refuses a photograph that a service named by mistake.
  @byte_limit 4 * 1024 * 1024

  @doc """
  The name of the entry for one address, if the cache holds it.

  It gives `nil` for an address that the cache does not hold, and for an address that
  is absent. A caller then shows no picture and asks for a copy.
  """
  @spec name(String.t() | nil) :: String.t() | nil
  def name(url) when is_binary(url) and url != "" do
    key = hash(url)

    case Cache.fetch(@namespace, key) do
      {:ok, _entry} -> key
      {:error, _reason} -> nil
    end
  end

  def name(_url), do: nil

  @doc """
  The address that draws the thumbnail of one picture.

  **It reads nothing.** The name of an entry is the hash of the address, so this builds
  the address from the address alone. A list of 100 rows therefore costs no query and no
  job to draw, where `name/1` costs one read of the cache for each row and
  `MyHiFi.Artwork.Worker.enqueue/1` costs a write for each row that the cache misses.
  `MyHiFiWeb.ItemList` draws a list again for each event of the player, so that cost
  arrives once a second while a track plays.

  The address of a picture that the cache does not hold answers 404, and a browser then
  shows nothing for that picture. A caller therefore draws its own mark behind the
  picture, and a row of a container shows a folder until the picture arrives.

      iex> MyHiFi.Artwork.thumbnail_path(nil)
      nil

  """
  @spec thumbnail_path(String.t() | nil) :: String.t() | nil
  def thumbnail_path(url) when is_binary(url) and url != "",
    do: "/artwork/#{hash(url)}/thumbnail"

  def thumbnail_path(_url), do: nil

  @doc """
  Everything that the web interface needs to send one picture.

  It gives the path, the type and the entity tag in one read, and it notes that
  something used the entry, which is what orders the eviction. See `MyHiFi.Cache`.

  The entity tag is the checksum of the bytes, which `MyHiFi.Cache` writes for each
  entry that arrives as bytes. Every picture and every thumbnail arrives that way, so
  the field always holds a value here.

  `name` comes from a request, so a name that is not a hash gives `:error` and no
  request reads another file of the partition. A type that this module does not serve
  gives `:error` as well, because the cache holds any bytes and this route must send
  an image alone.
  """
  @spec serve(String.t()) :: {:ok, Path.t(), String.t(), String.t()} | :error
  def serve(name) do
    with true <- hash?(name),
         {:ok, entry} <- Cache.fetch(@namespace, name),
         true <- entry.content_type in @served_types,
         path = path(entry),
         true <- File.exists?(path) do
      Cache.used(entry)
      {:ok, path, entry.content_type, entry.checksum}
    else
      _other -> :error
    end
  end

  @doc """
  Read one address and store the answer.

  It gives the name of the entry. It refuses an answer that is not an image of a type
  that this module serves, and it refuses one that is too large for a picture.

  The bytes decide the type, and the header of the answer does not. Of the 11 New
  Zealand stations that answer `image/x-icon`, 5 send a JPEG and 3 send a PNG.
  """
  @spec fetch(String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch(url) when is_binary(url) and url != "" do
    if readable?(url) do
      case name(url) do
        nil -> download(url)
        name -> {:ok, name}
      end
    else
      {:error, :no_address}
    end
  end

  def fetch(_url), do: {:error, :no_address}

  @doc """
  Hold a picture that a person gave, and give the name of the entry.

  A person gives bytes and no address, so the name of the entry is the hash of the
  bytes. That name holds 64 hexadecimal characters like every other name here, so
  `serve/1`, `serve_thumbnail/1` and `accent/1` take it and no route needs a rule of
  its own. The same file twice is therefore one entry.

  **The entry stays against every eviction.** No address can read these bytes again, so
  an eviction that took them would leave a setting that names a picture which is gone.
  See `MyHiFi.Device.Identity`.

  It refuses a GIF and a WebP. libvips in this firmware writes neither type, so such a
  picture can never hold a thumbnail, and a screen of this device draws the thumbnail
  and never the picture. The person who gave the file learns that at the moment that
  they give it.

  A host build holds no `vipsthumbnail`, and that one fault gives no error: the picture
  is held, and the screen of a target is where the thumbnail matters.
  """
  @spec put(binary()) :: {:ok, String.t()} | {:error, term()}
  def put(bytes) when is_binary(bytes) do
    with {:ok, content_type} <- given_type(bytes),
         :ok <- small_enough(bytes),
         {:ok, entry} <-
           Cache.put(@namespace, hash(bytes), %{
             bytes: bytes,
             content_type: content_type,
             keep?: true
           }),
         :ok <- thumbnail_of(entry) do
      # A picture of 4 MB can put the cache over its limit, so the eviction runs at the
      # moment that the cache grew, as it does for a logo that arrives.
      Cache.prune()
      {:ok, entry.entry_key}
    end
  end

  @doc """
  Remove one picture, and the thumbnail of it.

  A name that the cache does not hold gives `:ok`, because the cache then holds what
  the caller asked for.
  """
  @spec remove(String.t()) :: :ok
  def remove(name) do
    case Cache.fetch(@namespace, name) do
      {:ok, entry} ->
        Cache.purge!(entry)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Whether this firmware can read one address.

  **4 of the 247 New Zealand stations name the text `"null"` as their logo**,
  because that is what Radio Browser sends. `Req` raises for an address that holds
  no scheme, so a caller of `fetch/1` got an exception and not an error, and
  `MyHiFi.Artwork.Worker` then failed three times for a station that can never hold
  a picture.

  A feed of a podcast writes its own addresses, so this guards every caller and not
  the station list alone.
  """
  @spec readable?(String.t() | nil) :: boolean()
  def readable?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _other ->
        false
    end
  end

  def readable?(_url), do: false

  @doc """
  Where the pictures live.

  A test removes this directory. The cache holds each namespace in a directory of its
  own.
  """
  @spec directory() :: Path.t()
  def directory, do: Path.join(Cache.directory(), @namespace)

  @doc """
  The namespace that the cache holds a picture under.

  `MyHiFi.Device.Storage.Usage` reads it, so the storage report names the same
  namespace that this module writes. See `MyHiFi.Player.Download.namespace/0`.
  """
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc """
  The path of one entry.

  Nothing outside this module builds a path, because the cache names the file.
  """
  @spec path(MyHiFi.Cache.Entry.t()) :: Path.t()
  def path(entry), do: Path.join(Cache.directory(), entry.key)

  @doc """
  Make a thumbnail of one artwork entry.

  It reads the source file, runs `vipsthumbnail`, and writes the answer to the cache
  as an entry of its own. That entry holds `variant_of_blob_id`, which names the
  picture, so a caller finds one from the other.

  A source that is not JPEG or PNG gives no thumbnail, because libvips in this
  firmware writes neither WebP nor GIF.

  A source that already holds a thumbnail of these settings does nothing and gives
  that one. A thumbnail that an older build wrote holds another digest, and this
  writes a new one over it. See `MyHiFi.Artwork.Thumbnail.digest/0`.
  """
  @spec generate_thumbnail(MyHiFi.Cache.Entry.t()) ::
          {:ok, MyHiFi.Cache.Entry.t()} | {:error, term()}
  def generate_thumbnail(entry) do
    if Thumbnail.accept?(entry.content_type) do
      case existing_thumbnail(entry) do
        nil -> create_thumbnail(entry)
        variant -> current_thumbnail(entry, variant)
      end
    else
      {:error, :unsupported_format}
    end
  end

  @doc """
  The thumbnail of one artwork entry, if it exists.

  It gives `nil` for an entry that holds no thumbnail, or for an entry that is
  absent. A caller then shows the original or no picture.
  """
  @spec thumbnail(MyHiFi.Cache.Entry.t()) :: MyHiFi.Cache.Entry.t() | nil
  def thumbnail(entry), do: existing_thumbnail(entry)

  @doc """
  The name of the thumbnail for one address, if the cache holds it.

  It gives `nil` for an address that the cache does not hold, for one that holds
  no thumbnail, or for an address that is absent.
  """
  @spec thumbnail_name(String.t() | nil) :: String.t() | nil
  def thumbnail_name(url) when is_binary(url) and url != "" do
    key = hash(url)

    case Cache.fetch(@namespace, key) do
      {:ok, entry} ->
        case existing_thumbnail(entry) do
          nil -> nil
          variant -> variant.entry_key
        end

      {:error, _reason} ->
        nil
    end
  end

  def thumbnail_name(_url), do: nil

  @doc """
  The colour that one picture gives to the interface, or `nil` for a picture that
  gives none.

  `MyHiFi.Artwork.Thumbnail` writes it when it makes the thumbnail, so this reads a
  row and no picture. The device screen and the web page both read this, and neither
  one holds a rule of its own. See `MyHiFi.Artwork.Accent`.

  A picture of greys gives `nil`, and so does a picture that holds no thumbnail: a
  WebP and a GIF each hold none.
  """
  @spec accent(String.t() | nil) :: Accent.t() | nil
  def accent(name) when is_binary(name) and name != "" do
    with true <- hash?(name),
         {:ok, entry} <- Cache.fetch(@namespace, name),
         variant when not is_nil(variant) <- existing_thumbnail(entry) do
      colour(variant.metadata)
    else
      _other -> nil
    end
  end

  def accent(_name), do: nil

  @doc """
  Everything that a caller needs to send one thumbnail.

  It gives the path, the type and the entity tag in one read, and it notes that
  something used the entry. See `serve/1`.

  The entity tag moves when the thumbnail moves, and a new build of
  `MyHiFi.Artwork.Thumbnail` is one thing that moves it. The address of a thumbnail
  holds the name of the picture alone, so the tag is what tells a browser that the
  bytes at that address are not the bytes that it holds.
  """
  @spec serve_thumbnail(String.t()) :: {:ok, Path.t(), String.t(), String.t()} | :error
  def serve_thumbnail(name) do
    with true <- hash?(name),
         {:ok, entry} <- Cache.fetch(@namespace, name),
         variant when not is_nil(variant) <- existing_thumbnail(entry),
         variant_path = path(variant),
         true <- File.exists?(variant_path) do
      # **The picture is used as well, and not the thumbnail alone.** A destroy of an
      # entry takes its variants with it, so an eviction that read the picture as cold
      # would take the thumbnail that a screen is drawing at that moment. The lists and
      # the screens of this firmware read thumbnails and almost never a picture, so
      # every source would have looked cold for as long as the device ran.
      Cache.used(entry)
      Cache.used(variant)
      {:ok, variant_path, variant.content_type, variant.checksum}
    else
      _other -> :error
    end
  end

  # The row holds the colour as the database gives it back, which is a map of strings.
  defp colour(%{"accent" => %{"lightness" => lightness, "chroma" => chroma, "hue" => hue}}) do
    %{lightness: lightness, chroma: chroma, hue: hue}
  end

  defp colour(_metadata), do: nil

  defp existing_thumbnail(entry) do
    entry
    |> Ash.load!(:variants)
    |> Map.get(:variants, [])
    |> Enum.find(fn variant -> variant.variant_name == "thumbnail" end)
  end

  defp current_thumbnail(entry, variant) do
    if variant.variant_digest == Thumbnail.digest() do
      {:ok, variant}
    else
      create_thumbnail(entry)
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp create_thumbnail(entry) do
    dest_path =
      Path.join(System.tmp_dir!(), "thumbnail_#{:erlang.unique_integer([:positive])}.jpg")

    try do
      with {:ok, metadata} <- Thumbnail.transform(path(entry), dest_path, []),
           {:ok, bytes} <- File.read(dest_path) do
        store_thumbnail(entry, bytes, metadata)
      end
    after
      File.rm(dest_path)
    end
  end

  # The cache writes the file and holds the row, as it does for the picture itself.
  # See the `:put` action of `MyHiFi.Cache.Entry` for why the variant action of
  # `AshStorage` cannot.
  defp store_thumbnail(source, bytes, metadata) do
    Cache.put(@namespace, thumbnail_key(source.entry_key), %{
      bytes: bytes,
      # A variant of an entry that stays against an eviction must stay with it. A
      # picture that a person gave holds `keep?`, and a screen draws the thumbnail and
      # never the picture, so a thumbnail that an eviction took would empty the screen
      # and leave the bytes that made it on the card.
      keep?: source.keep?,
      content_type: Map.get(metadata, :content_type, source.content_type),
      metadata: Map.drop(metadata, [:content_type, :filename]),
      variant_of_blob_id: source.id,
      variant_name: "thumbnail",
      variant_digest: Thumbnail.digest()
    })
  end

  # The key of the picture and a name for what this is. It holds no hash of 64
  # characters, so `serve/1` refuses it and the thumbnail route is the one way to it.
  defp thumbnail_key(source_key), do: "#{source_key}.thumbnail"

  defp given_type(bytes) do
    with {:ok, extension} <- extension(bytes, "an upload") do
      content_type = Map.fetch!(@content_types, extension)

      if Thumbnail.accept?(content_type),
        do: {:ok, content_type},
        else: {:error, {:not_an_image, content_type}}
    end
  end

  defp small_enough(bytes) when byte_size(bytes) > @byte_limit,
    do: {:error, {:too_large, byte_size(bytes)}}

  defp small_enough(_bytes), do: :ok

  # A host build holds no `vipsthumbnail`, and a picture without one still belongs to
  # the device. Every other fault reaches the person who gave the file.
  defp thumbnail_of(entry) do
    case generate_thumbnail(entry) do
      {:ok, _variant} -> :ok
      {:error, :vipsthumbnail_not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp download(url) do
    with {:ok, response} <- get(url),
         {:ok, body} <- body(response),
         {:ok, extension} <- extension(body, declared_type(response)) do
      store(url, body, Map.fetch!(@content_types, extension))
    end
  end

  defp store(url, body, content_type) do
    case Cache.put(@namespace, hash(url), %{bytes: body, content_type: content_type}) do
      {:ok, entry} ->
        # A picture of a podcast is 1.2 MB, so one arrival can put the cache over its
        # limit. The eviction runs here and not on a schedule, because that is the
        # moment when the cache grew.
        Cache.prune()
        {:ok, entry.entry_key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get(url) do
    case Req.get(request(), url: url) do
      {:ok, %{status: 200} = response} -> {:ok, response}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The first bytes give the type, and the `content-type` header does not. A station
  # server often names the wrong type, and the header alone therefore threw away a
  # logo of 600 by 600 pixels. Each format below starts with bytes of its own.
  #
  # The header stays for the message alone, because a person who reads the log wants
  # to know what the server said.
  defp extension(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>, _declared), do: {:ok, "png"}

  defp extension(<<0xFF, 0xD8, 0xFF, _rest::binary>>, _declared), do: {:ok, "jpg"}

  defp extension(<<"GIF87a", _rest::binary>>, _declared), do: {:ok, "gif"}

  defp extension(<<"GIF89a", _rest::binary>>, _declared), do: {:ok, "gif"}

  # A WebP file holds the count of its bytes between the two names.
  defp extension(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>, _declared),
    do: {:ok, "webp"}

  defp extension(_body, declared), do: {:error, {:not_an_image, declared}}

  defp declared_type(response) do
    response
    |> Req.Response.get_header("content-type")
    |> List.first()
    |> to_string()
    |> String.split(";")
    |> List.first()
    |> String.trim()
    |> String.downcase()
  end

  defp body(%{body: body}) when is_binary(body) and byte_size(body) > 0 do
    if byte_size(body) > @byte_limit do
      {:error, {:too_large, byte_size(body)}}
    else
      {:ok, body}
    end
  end

  defp body(_response), do: {:error, :empty}

  # A name comes from a request, so it holds 64 hexadecimal characters or nothing at
  # all reads a file.
  defp hash?(name) when is_binary(name) and byte_size(name) == 64 do
    String.match?(name, ~r/^[0-9a-f]{64}$/)
  end

  defp hash?(_name), do: false

  defp hash(url), do: :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)

  # A test gives a stub with `config :my_hi_fi, MyHiFi.Artwork, plug: ...`. Nothing
  # sets this in production.
  defp request do
    [receive_timeout: :timer.seconds(15), retry: :transient]
    |> Keyword.merge(Application.get_env(:my_hi_fi, __MODULE__, []))
    |> Req.new()
  end
end
