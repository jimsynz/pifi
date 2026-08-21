defmodule MyHiFi.Artwork do
  @moduledoc """
  The local copy of a station logo.

  A station names its logo with an address on the internet. The web interface
  serves the copy instead, for two reasons. A page then shows a logo when the
  internet is not there, and the content security policy of the device holds
  `'self'` alone, so no page asks another server for anything.

  A file lives under the application data partition, and its name is a hash of the
  address. The same address therefore gives the same file, and no name from a
  station reaches the file system.

  The cache holds a limit, and the limit comes from the free space of the
  partition. The oldest file goes first when the cache is at that limit. A logo is
  small: 247 New Zealand stations need about 5 MB.
  """

  # A path here comes from a hash of this module, or from the module attribute
  # below. It never comes from a request. Sobelow reads `@sobelow_skip` from the
  # source, and this registration stops the compiler warning that no Elixir code
  # reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  require Logger

  @directory "artwork"
  @max_bytes 64 * 1024 * 1024
  @free_space_share 20
  @byte_limit 4 * 1024 * 1024

  # A station sends one of these, and this firmware serves what it stored. A type
  # that is absent here never reaches the disk.
  #
  # SVG is absent on purpose. An SVG file can hold a script, and this device serves
  # each logo from its own address, so such a script would run with the rights of
  # the web interface. A logo of a station is a raster image in each case that this
  # project has seen.
  @types %{
    "image/png" => "png",
    "image/jpeg" => "jpg",
    "image/jpg" => "jpg",
    "image/gif" => "gif",
    "image/webp" => "webp"
  }

  @content_types %{
    "png" => "image/png",
    "jpg" => "image/jpeg",
    "gif" => "image/gif",
    "webp" => "image/webp"
  }

  @doc """
  The name of the file for one address, if the cache holds it.

  It gives `nil` for an address that the cache does not hold, and for an address
  that is absent. A caller then shows no logo and asks for a copy.
  """
  @spec name(String.t() | nil) :: String.t() | nil
  def name(url) when is_binary(url) and url != "" do
    hash = hash(url)

    Enum.find_value(Map.values(@types), fn extension ->
      candidate = "#{hash}.#{extension}"

      if File.exists?(path(candidate)), do: candidate
    end)
  end

  def name(_url), do: nil

  @doc """
  The path of one file of the cache.

  `name` comes from `name/1` or from a request. A name that is not a hash and an
  extension of this module gives `nil`, so no request reads another file.
  """
  @spec path(String.t()) :: Path.t() | nil
  def path(name) do
    if valid_name?(name), do: Path.join(directory(), name)
  end

  @doc "Where the cache lives."
  @spec directory() :: Path.t()
  def directory, do: Path.join(MyHiFi.Device.storage!().path, @directory)

  @doc """
  The content type of one file of the cache.

  Each answer is an image that holds no script, so a browser cannot run anything
  from this address. It gives `nil` for a name that this module does not serve.
  """
  @spec content_type(String.t()) :: String.t() | nil
  def content_type(name) do
    if valid_name?(name) do
      Map.get(@content_types, name |> Path.extname() |> String.trim_leading("."))
    end
  end

  @doc """
  Read one address and store the answer.

  It gives the name of the file. It refuses an answer that is not an image of a
  type that this module serves, and it refuses one that is too large for a logo.
  """
  @spec fetch(String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch(url) when is_binary(url) and url != "" do
    case name(url) do
      nil -> download(url)
      name -> {:ok, name}
    end
  end

  def fetch(_url), do: {:error, :no_address}

  @doc """
  Remove the oldest files until the cache is inside its limit.

  It gives the count of the files that it removed.
  """
  @spec prune() :: non_neg_integer()
  def prune do
    files = files()
    total = files |> Enum.map(& &1.size) |> Enum.sum()
    limit = limit()

    if total <= limit do
      0
    else
      removed = remove_oldest(files, total, limit)
      Logger.info("The artwork cache held #{total} bytes. Removed #{removed} files.")
      removed
    end
  end

  @doc """
  How many bytes the cache may hold.

  A logo needs little, so the limit is a small part of the free space, and it stops
  at 64 MB. A partition that is almost full gives a small limit, and the device
  keeps the room for the database.

  A test sets `:artwork_max_bytes` to a small number, so it can fill the cache and
  watch the oldest file go.
  """
  @spec limit() :: non_neg_integer()
  def limit do
    storage = MyHiFi.Device.storage!()
    max_bytes = Application.get_env(:my_hi_fi, :artwork_max_bytes, @max_bytes)

    min(max_bytes, div(storage.free_bytes, @free_space_share))
  end

  # Each path comes from `files/0`, and that function reads the cache directory
  # only. No name from a request reaches this.
  @sobelow_skip ["Traversal.FileModule"]
  defp remove_oldest(files, total, limit) do
    files
    |> Enum.sort_by(& &1.written_at)
    |> Enum.reduce_while({total, 0}, fn file, {held, removed} ->
      if held <= limit do
        {:halt, {held, removed}}
      else
        File.rm(file.path)
        {:cont, {held - file.size, removed + 1}}
      end
    end)
    |> elem(1)
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp download(url) do
    with {:ok, response} <- get(url),
         {:ok, extension} <- extension(response),
         {:ok, body} <- body(response) do
      name = "#{hash(url)}.#{extension}"
      path = Path.join(directory(), name)

      File.mkdir_p(directory())

      case File.write(path, body) do
        :ok ->
          prune()
          {:ok, name}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp get(url) do
    case Req.get(request(), url: url) do
      {:ok, %{status: 200} = response} -> {:ok, response}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extension(response) do
    type =
      response
      |> Req.Response.get_header("content-type")
      |> List.first()
      |> to_string()
      |> String.split(";")
      |> List.first()
      |> String.trim()
      |> String.downcase()

    case Map.fetch(@types, type) do
      {:ok, extension} -> {:ok, extension}
      :error -> {:error, {:not_an_image, type}}
    end
  end

  defp body(%{body: body}) when is_binary(body) and byte_size(body) > 0 do
    if byte_size(body) > @byte_limit do
      {:error, {:too_large, byte_size(body)}}
    else
      {:ok, body}
    end
  end

  defp body(_response), do: {:error, :empty}

  defp files do
    directory()
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{type: :regular, size: size, mtime: written_at}} ->
          [%{path: path, size: size, written_at: written_at}]

        _other ->
          []
      end
    end)
  end

  # A name holds 64 hexadecimal characters, a dot, and one of the extensions
  # above. Nothing else reaches the file system.
  defp valid_name?(name) when is_binary(name) do
    case String.split(name, ".") do
      [hash, extension] ->
        extension in Map.values(@types) and String.length(hash) == 64 and
          String.match?(hash, ~r/\A[0-9a-f]{64}\z/)

      _other ->
        false
    end
  end

  defp valid_name?(_name), do: false

  defp hash(url), do: :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)

  defp request do
    :my_hi_fi
    |> Application.get_env(__MODULE__, [])
    |> Keyword.put_new(:receive_timeout, :timer.seconds(15))
    |> Keyword.put_new(:retry, false)
    |> Keyword.put_new(:max_redirects, 3)
    |> Req.new()
  end
end
