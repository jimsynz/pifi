defmodule PiFiWeb.ArtworkController do
  @moduledoc """
  Serves a station logo from the local cache.

  The name comes from a request, and `PiFi.Artwork.serve/1` gives a path for a name
  that is a hash and nothing else. Any other name gives 404, so no request reads another file
  of the partition.

  That call also notes that something used the entry, which is what orders the
  eviction of the cache. See `PiFi.Cache`.
  """

  use PiFiWeb, :controller

  # Sobelow reads `@sobelow_skip` from the source. This registration stops the
  # compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  alias PiFi.Artwork

  @one_week 7 * 24 * 60 * 60

  # `PiFi.Artwork.serve/1` returns one of four image types, and none of them can
  # carry a script. The cache keeps any bytes, so that function refuses a type that this
  # route does not serve, and a name that it does not know gives 404.
  def show(conn, %{"name" => name}) do
    case Artwork.serve(name) do
      {:ok, path, type, etag} -> send_picture(conn, path, type, etag)
      :error -> send_resp(conn, 404, "")
    end
  end

  @doc """
  Serves a thumbnail of one artwork entry.

  The name comes from a request, and `PiFi.Artwork.serve_thumbnail/1` gives a
  path for a name that is a hash and nothing else. Any other name gives 404.
  """
  def thumbnail(conn, %{"name" => name}) do
    case Artwork.serve_thumbnail(name) do
      {:ok, path, type, etag} -> send_picture(conn, path, type, etag)
      :error -> send_resp(conn, 404, "")
    end
  end

  # The entity tag is the checksum of the bytes. A browser that already has the picture
  # sends the tag back in `if-none-match`, and this then answers 304 and no bytes.
  #
  # **`immutable` is absent from the cache control on purpose.** It tells a browser
  # to send no such request at all, and the bytes at one address do change: a build
  # that changes `PiFi.Artwork.Thumbnail` writes a new thumbnail, and the address
  # of a thumbnail carries the name of the picture alone.
  @sobelow_skip ["XSS.ContentType"]
  defp send_picture(conn, path, type, etag) do
    tag = ~s("#{etag}")

    conn =
      conn
      # A binary image has no characters, so it needs no charset.
      |> put_resp_content_type(type, nil)
      |> put_resp_header("cache-control", "public, max-age=#{@one_week}")
      |> put_resp_header("etag", tag)

    if held?(conn, tag) do
      send_resp(conn, 304, "")
    else
      send_artwork(conn, path)
    end
  end

  # A browser sends one tag, and `*` and a list of tags are both allowed.
  defp held?(conn, tag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 == tag or &1 == "*"))
  end

  # The path and the type come from `PiFi.Artwork.serve/1`, which answers for a
  # name that is a hash and nothing else, and each type is an image that can carry no
  # script.
  @sobelow_skip ["Traversal.SendFile"]
  defp send_artwork(conn, path), do: send_file(conn, 200, path)
end
