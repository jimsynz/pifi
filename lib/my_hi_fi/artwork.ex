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
  """

  alias MyHiFi.Cache

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
  Everything that the web interface needs to send one picture.

  It gives the path and the type in one read, and it notes that something used the
  entry, which is what orders the eviction. See `MyHiFi.Cache`.

  `name` comes from a request, so a name that is not a hash gives `:error` and no
  request reads another file of the partition. A type that this module does not serve
  gives `:error` as well, because the cache holds any bytes and this route must send
  an image alone.
  """
  @spec serve(String.t()) :: {:ok, Path.t(), String.t()} | :error
  def serve(name) do
    with true <- hash?(name),
         {:ok, entry} <- Cache.fetch(@namespace, name),
         true <- entry.content_type in @served_types,
         path = path(entry),
         true <- File.exists?(path) do
      Cache.touch(entry)
      {:ok, path, entry.content_type}
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
  The path of one entry.

  Nothing outside this module builds a path, because the cache names the file.
  """
  @spec path(MyHiFi.Cache.Entry.t()) :: Path.t()
  def path(entry), do: Path.join(Cache.directory(), entry.key)

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
