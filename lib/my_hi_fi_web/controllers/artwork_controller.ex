defmodule MyHiFiWeb.ArtworkController do
  @moduledoc """
  Serves a station logo from the local cache.

  The name comes from a request, and `MyHiFi.Artwork.path/1` gives a path for a
  name that holds a hash and a known extension only. Any other name gives 404, so
  no request reads another file of the partition.
  """

  use MyHiFiWeb, :controller

  # Sobelow reads `@sobelow_skip` from the source. This registration stops the
  # compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  alias MyHiFi.Artwork

  @one_week 7 * 24 * 60 * 60

  # `MyHiFi.Artwork.content_type/1` gives one of four image types, and each one
  # holds no script. A name that it does not know gives 404.
  @sobelow_skip ["XSS.ContentType"]
  def show(conn, %{"name" => name}) do
    with path when is_binary(path) <- Artwork.path(name),
         type when is_binary(type) <- Artwork.content_type(name),
         true <- File.exists?(path) do
      conn
      # A binary image holds no characters, so it needs no charset.
      |> put_resp_content_type(type, nil)
      |> put_resp_header("cache-control", "public, max-age=#{@one_week}, immutable")
      |> send_artwork(path)
    else
      _other -> send_resp(conn, 404, "")
    end
  end

  # The path comes from `MyHiFi.Artwork.path/1`, and the type from
  # `MyHiFi.Artwork.content_type/1`. Both give an answer for a name that holds a
  # hash and a known extension only, and each type is an image that holds no
  # script.
  @sobelow_skip ["Traversal.SendFile"]
  defp send_artwork(conn, path), do: send_file(conn, 200, path)
end
