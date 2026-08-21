defmodule MyHiFi.Source.InternetRadio do
  @moduledoc """
  Internet radio, from the local copy of the Radio Browser station list.

  The tree has three branches under the root.

      Favourites          the stations that a person marked
      Countries           one container for each country in the table
        NZ                the stations of that country
      Tags                one container for each tag in the table
        classic rock      the stations that carry that tag

  A station is a track, and it has no length, because a radio stream is live.

  `MyHiFi.Radio.Station.SyncFromRemote` fills the table, so this module reaches no
  network. A search works when the internet does not.
  """

  @behaviour MyHiFi.Source

  alias MyHiFi.Player.Hls
  alias MyHiFi.Radio

  @default_limit 100

  @impl MyHiFi.Source
  def title, do: "Internet radio"

  @impl MyHiFi.Source
  def root, do: :root

  @impl MyHiFi.Source
  def browse(ref, options \\ [])

  def browse(:root, _options) do
    {:ok,
     page([
       {:container, %{ref: :favourites, title: "Favourites", artwork: nil}},
       {:container, %{ref: :countries, title: "Countries", artwork: nil}},
       {:container, %{ref: :tags, title: "Tags", artwork: nil}}
     ])}
  end

  def browse(:favourites, options) do
    {:ok, tracks(Radio.favourite_stations!(), options)}
  end

  def browse(:countries, options) do
    containers =
      Radio.list_stations!(query: [select: [:country_code]])
      |> Enum.map(& &1.country_code)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&{:container, %{ref: {:country, &1}, title: &1, artwork: nil}})

    {:ok, paginate(containers, options)}
  end

  def browse({:country, code}, options) do
    {:ok, tracks(Radio.stations_by_country!(code), options)}
  end

  def browse(:tags, options) do
    containers =
      Radio.list_stations!(query: [select: [:tags]])
      |> Enum.flat_map(& &1.tags)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&{:container, %{ref: {:tag, &1}, title: &1, artwork: nil}})

    {:ok, paginate(containers, options)}
  end

  def browse({:tag, tag}, options) do
    {:ok, tracks(Radio.stations_by_tag!(tag), options)}
  end

  def browse(ref, _options), do: {:error, {:no_such_container, ref}}

  @impl MyHiFi.Source
  def search(query, options \\ []) do
    {:ok, tracks(Radio.search_stations!(query), options)}
  end

  @impl MyHiFi.Source
  def track({:station, id}) do
    case Radio.get_station(id) do
      {:ok, station} -> {:ok, to_track(station)}
      {:error, reason} -> {:error, reason}
    end
  end

  def track(ref), do: {:error, {:not_a_track, ref}}

  @impl MyHiFi.Source
  def resolve({:station, id}) do
    with {:ok, station} <- Radio.get_station(id), do: playable(station)
  end

  def resolve(ref), do: {:error, {:not_a_track, ref}}

  # An HLS address gives a playlist, and the playlist holds the container and the
  # codec. `MyHiFi.Player.Hls` reads it. This is the one function of this module
  # that needs the network.
  defp playable(%{hls?: true} = station) do
    case Hls.resolve(station.stream_url, hls_codec(station)) do
      {:ok, hls} ->
        {:ok,
         %{
           uri: URI.to_string(hls.media_playlist_uri),
           headers: [],
           transport: :hls,
           container: hls.container,
           format: hls.format,
           live?: true
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp playable(station) do
    {:ok,
     %{
       uri: station.stream_url,
       headers: [],
       transport: :http,
       container: :none,
       format: format(station),
       live?: true
     }}
  end

  # The playlist names the codec in almost every case, and this answer applies
  # only when it does not. HLS radio carries AAC far more often than MP3.
  defp hls_codec(%{codec: codec}) do
    case codec_format(codec) do
      :mp3 -> :mp3
      _other -> :aac
    end
  end

  # A station holds a UUID, and a UUID holds no colon, so this name needs no
  # escape rule. A tag holds any character, so a container ref would need one, and
  # the player stores the tracks only.
  @impl MyHiFi.Source
  def ref_to_string({:station, id}), do: {:ok, "station:" <> id}

  def ref_to_string(_ref), do: {:error, :cannot_name}

  @impl MyHiFi.Source
  def ref_from_string("station:" <> id) do
    # Ash reads an empty string as `nil`, and a name with no UUID must not give a
    # ref that names no station.
    case Ash.Type.cast_input(Ash.Type.UUID, id) do
      {:ok, id} when is_binary(id) -> {:ok, {:station, id}}
      _other -> {:error, :not_a_name}
    end
  end

  def ref_from_string(_name), do: {:error, :not_a_name}

  @impl MyHiFi.Source
  def favourite({:station, id}, true?) do
    with {:ok, station} <- Radio.get_station(id),
         {:ok, _station} <- mark(station, true?) do
      :ok
    end
  end

  def favourite(ref, _true?), do: {:error, {:not_a_track, ref}}

  @doc """
  The codec that a station names.

  This is what the service reports, and it is a guess for an HLS station: the
  playlist of such a station holds the codec, and `MyHiFi.Player.Hls` reads it.
  """
  @spec format(MyHiFi.Radio.Station.t()) :: :mp3 | :aac | :flac | :ogg | :unknown
  def format(%{codec: codec}), do: codec_format(codec)

  defp codec_format(nil), do: :unknown

  defp codec_format(codec) do
    case String.upcase(codec) do
      "MP3" -> :mp3
      "AAC" -> :aac
      "AAC+" -> :aac
      "FLAC" -> :flac
      "OGG" -> :ogg
      _other -> :unknown
    end
  end

  defp tracks(stations, options) do
    stations
    |> Enum.map(&{:track, to_track(&1)})
    |> paginate(options)
  end

  defp mark(station, true), do: Radio.set_favourite(station)
  defp mark(station, false), do: Radio.clear_favourite(station)

  defp to_track(station) do
    %{
      ref: {:station, station.id},
      title: station.title,
      subtitle: subtitle(station),
      artwork: station.artwork_url,
      # A radio stream is live, so it has no length.
      duration_ms: nil,
      favourite?: station.favourite?
    }
  end

  # The codec and the bitrate tell a person what to expect of the sound.
  defp subtitle(%{codec: nil, bitrate: _bitrate}), do: nil
  defp subtitle(%{codec: codec, bitrate: nil}), do: codec
  defp subtitle(%{codec: codec, bitrate: 0}), do: codec
  defp subtitle(%{codec: codec, bitrate: bitrate}), do: "#{codec}, #{bitrate} kbps"

  defp page(entries, cursor \\ nil), do: %{entries: entries, cursor: cursor}

  defp paginate(entries, options) do
    limit = Keyword.get(options, :limit, @default_limit)
    offset = Keyword.get(options, :cursor, 0)

    taken = entries |> Enum.drop(offset) |> Enum.take(limit)
    next = offset + length(taken)

    if next < length(entries) do
      page(taken, next)
    else
      page(taken)
    end
  end
end
