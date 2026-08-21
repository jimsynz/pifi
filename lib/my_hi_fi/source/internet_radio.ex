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
  def resolve({:station, id}) do
    case Radio.get_station(id) do
      {:ok, station} ->
        {:ok,
         %{
           uri: station.stream_url,
           headers: [],
           format: format(station),
           live?: true
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def resolve(ref), do: {:error, {:not_a_track, ref}}

  @doc """
  The pipeline that a station needs.

  HLS comes first, because a station that sends HLS names a codec as well, and
  the container decides the pipeline.
  """
  @spec format(MyHiFi.Radio.Station.t()) :: :mp3 | :aac | :flac | :ogg | :hls | :unknown
  def format(%{hls?: true}), do: :hls
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
    |> Enum.map(fn station ->
      {:track,
       %{
         ref: {:station, station.id},
         title: station.title,
         subtitle: subtitle(station),
         artwork: station.artwork_url,
         # A radio stream is live, so it has no length.
         duration_ms: nil
       }}
    end)
    |> paginate(options)
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
