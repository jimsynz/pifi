defmodule MyHiFi.Source.InternetRadio do
  @moduledoc """
  Internet radio, from the local copy of the Radio Browser station list.

  The tree has three branches under the root.

      Favourites          the stations that a person marked
      Countries           one container for each country in the catalogue
        NZ                the stations of that country
      Tags                one container for each tag in the catalogue
        classic rock      the stations that carry that tag

  A station is a track, and it has no length, because a radio stream is live.

  `MyHiFi.Radio.Fill` writes the stations into `MyHiFi.Playback`, so this module holds
  no table of its own and it reaches no network to browse. A search works when the
  internet does not.

  A `ref` is `{:station, id}`, and the id is the id of a `MyHiFi.Playback.Item`. A
  country and a tag are containers, and each one names a `MyHiFi.Playback.Facet`.

  ## The one place that needs the network

  `resolve/1` reads it. An HLS address gives a playlist, and the playlist holds the
  container and the codec. Ogg is a container, and the service reports the codec `OGG`
  for each codec inside it, so the first page of the stream names the true one.
  `transport` and `format` of an item hold what the service claims, and this function
  gives what is true.
  """

  @behaviour MyHiFi.Source

  require Ash.Query

  alias MyHiFi.Playback.Facet
  alias MyHiFi.Playback.Item
  alias MyHiFi.Player.Hls
  alias MyHiFi.Player.Ogg
  alias MyHiFi.Radio.Sync.FromRemote

  @source "internet-radio"

  @impl MyHiFi.Source
  def title, do: "Internet radio"

  @impl MyHiFi.Source
  def icon, do: :radio

  # A radio stream is live, so a person cannot move inside it and `:skip` is not here.
  # Next and previous move through the favourites, in the way that the preset controls
  # of a stereo do.
  @impl MyHiFi.Source
  def capabilities, do: [:search]

  # A station plays, and no station holds another one.
  @impl MyHiFi.Source
  def kinds, do: [track: "Stations"]

  @impl MyHiFi.Source
  def roots do
    [
      {"Favourites", %{query: favourites_query(), kind: :item}},
      {"Countries", %{query: facet_query("country"), kind: :facet}},
      {"Tags", %{query: facet_query("tag"), kind: :facet}}
    ]
  end

  defp favourites_query do
    Item
    |> Ash.Query.filter(source == ^@source and favourite? == true)
    |> Ash.Query.sort(title: :asc)
  end

  defp facet_query(key) do
    Facet
    |> Ash.Query.for_read(:by_key, %{key: key})
  end

  # A sync writes every station on to the card, so the catalogue is the whole list and
  # this reaches no service. The text is therefore not needed here.
  @impl MyHiFi.Source
  def search(_text) do
    Item
    |> Ash.Query.filter(source == ^@source)
    |> Ash.Query.sort(rank: :desc, title: :asc)
  end

  @impl MyHiFi.Source
  def resolve(%{kind: :track} = item), do: playable(item)

  def resolve(item), do: {:error, {:not_a_track, item.id}}

  # A station that no read of the service has filled holds the mark of a person and
  # nothing to play. `MyHiFi.Radio.CarryFavourites` writes one, and the next sync
  # fills it. This is first, because an address of `nil` reaches the network below.
  defp playable(%{url: url, format: format} = item) when is_nil(url) or is_nil(format) do
    {:error, {:not_read_yet, item.title}}
  end

  # An HLS address gives a playlist, and the playlist holds the container and the
  # codec. `MyHiFi.Player.Hls` reads it. This is the one function of this module
  # that needs the network.
  defp playable(%{transport: :hls} = item) do
    case Hls.resolve(item.url, hls_codec(item)) do
      {:ok, hls} ->
        {:ok,
         %{
           uri: URI.to_string(hls.media_playlist_uri),
           headers: [],
           transport: :hls,
           container: hls.container,
           format: hls.format,
           live?: true,
           position_ms: 0
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Ogg is a container, and the service reports the codec `OGG` for each codec
  # inside it. The first page of the stream names the codec, so this reads it. See
  # `MyHiFi.Player.Ogg`.
  defp playable(%{format: format} = item) when format in [:vorbis, :flac] do
    case Ogg.codec(item.url) do
      {:ok, inside} ->
        {:ok, http_playable(item, :ogg, inside)}

      # A station that names FLAC and holds no Ogg container sends FLAC as it is.
      {:error, _reason} ->
        {:ok, http_playable(item, :none, item.format)}
    end
  end

  defp playable(item), do: {:ok, http_playable(item, :none, item.format)}

  defp http_playable(item, container, format) do
    %{
      uri: item.url,
      headers: [],
      transport: :http,
      container: container,
      format: format,
      live?: true,
      # A live stream holds no place, so it always begins where it begins.
      position_ms: 0
    }
  end

  # The playlist names the codec in almost every case, and this answer applies
  # only when it does not. HLS radio carries AAC far more often than MP3.
  defp hls_codec(%{format: :mp3}), do: :mp3
  defp hls_codec(_item), do: :aac

  @impl MyHiFi.Source
  def settings do
    [
      %{
        key: "countries",
        title: "Station countries",
        description:
          "Name each country by its two letter code, and put a comma between them. " <>
            "The station list holds #{stations(count())}.",
        link: nil,
        type: :text,
        value: Enum.join(FromRemote.configured_countries(), ", "),
        write_only?: false
      }
    ]
  end

  @impl MyHiFi.Source
  def put_settings(%{"countries" => text}) do
    case codes(text) do
      [] ->
        {:error, "Name at least one country, such as NZ."}

      codes ->
        MyHiFi.Settings.put!(FromRemote.countries_key(), Enum.join(codes, ","))

        {:ok, "The station list covers #{Enum.join(codes, ", ")}."}
    end
  end

  def put_settings(_values), do: {:error, "Name at least one country, such as NZ."}

  @impl MyHiFi.Source
  def settings_actions do
    [
      %{
        name: "sync",
        title: "Ask for the stations now",
        description: "A weekly job also does this by itself.",
        icon: :refresh
      }
    ]
  end

  @impl MyHiFi.Source
  def run_settings_action("sync") do
    case MyHiFi.Source.ask_for_job(MyHiFi.Radio.Sync, :sync_from_remote) do
      :queued ->
        {:ok, "The device asks for the station list of each country now."}

      :running ->
        {:ok,
         "The device asks for the station list already. A read that stopped without " <>
           "finishing starts again within two hours."}
    end
  end

  def run_settings_action(_name), do: {:error, "Internet radio holds no such control."}

  defp count, do: Ash.count!(Ash.Query.filter(Item, source == ^@source))

  # The station list is in the order that a person elsewhere chose. `rank` holds the
  # click count of the service, and it is a column because no data layer sorts on a
  # facet.
  defp codes(text) do
    text
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.upcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp stations(1), do: "1 station"
  defp stations(count), do: "#{count} stations"

  # The favourites, and in the same order, so this list is the list that
  # a person sees. The presets of a stereo have no end, so it moves round.
end
