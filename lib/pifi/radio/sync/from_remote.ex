defmodule PiFi.Radio.Sync.FromRemote do
  @moduledoc """
  Copies the station list of each chosen country into the local table.

  A weekly schedule runs this, and the first start of a device runs it once. It
  reads the country list from the settings, so a person changes the list on the
  settings page and the next run follows it.

  `PiFi.Radio.Fill` writes what it reads. A later run updates an item and does not
  add a second one, and it accepts nothing that belongs to a person, so a favourite
  and a place stay as they are.
  """

  use Ash.Resource.Actions.Implementation

  require Logger

  alias PiFi.Radio.Fill
  alias PiFi.Radio.RadioBrowser
  alias PiFi.Settings
  alias PiFi.Source

  @countries_key "station_countries"
  @default_countries "NZ"

  @doc """
  The settings key of the country list.
  """
  @spec countries_key() :: String.t()
  def countries_key, do: @countries_key

  @doc """
  The countries that a device copies when a person has chosen none.
  """
  @spec default_countries() :: String.t()
  def default_countries, do: @default_countries

  # A person who takes the internet radio source out of use expects the device to
  # ask the service for nothing. See `PiFi.Source.enabled?/1`.
  @impl true
  def run(input, _options, _context) do
    if Source.enabled?(Source.InternetRadio) do
      sync(input.arguments[:countries] || configured_countries())
    else
      {:ok, %{written: 0, failed: [], countries: [], skipped?: true}}
    end
  end

  defp sync(countries) do
    result =
      Enum.reduce(countries, %{written: 0, failed: []}, fn country, acc ->
        case sync_country(country) do
          {:ok, written} -> %{acc | written: acc.written + written}
          {:error, reason} -> %{acc | failed: [{country, reason} | acc.failed]}
        end
      end)

    # A sync that drops the last station of a country leaves that country behind, and
    # the browse tree must show no empty container.
    removed = Fill.tidy()

    Logger.info(
      "Station sync wrote #{result.written} stations from #{inspect(countries)}. " <>
        "#{length(result.failed)} countries failed, and #{removed} facets went."
    )

    {:ok,
     %{
       written: result.written,
       failed: Enum.reverse(result.failed),
       countries: countries,
       skipped?: false
     }}
  end

  @doc """
  Read the country list from the settings.

  It returns the default when a person has chosen none.
  """
  @spec configured_countries() :: [String.t()]
  def configured_countries do
    value =
      case Settings.fetch(@countries_key) do
        {:ok, setting} -> setting.value
        {:error, _reason} -> @default_countries
      end

    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp sync_country(country) do
    with {:ok, stations} <- RadioBrowser.stations_by_country(country) do
      written =
        stations
        |> Enum.filter(&playable?/1)
        |> Fill.stations()

      {:ok, written}
    end
  end

  # The service sends stations with no address and stations with no name. Neither can
  # play, and an item needs both.
  defp playable?(%{stream_url: url, title: title})
       when is_binary(url) and url != "" and is_binary(title) and title != "",
       do: true

  defp playable?(_attributes), do: false
end
