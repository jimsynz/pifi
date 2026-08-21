defmodule MyHiFi.Radio.Station.SyncFromRemote do
  @moduledoc """
  Copies the station list of each chosen country into the local table.

  A weekly schedule runs this, and the first start of a device runs it once. It
  reads the country list from the settings, so a person changes the list on the
  settings page and the next run follows it.

  It writes each station with `upsert_from_remote`, so a later run updates a row
  and does not add a second one. That action accepts nothing that belongs to a
  person, so a favourite and a play time stay as they are.
  """

  use Ash.Resource.Actions.Implementation

  require Logger

  alias MyHiFi.Radio
  alias MyHiFi.Radio.RadioBrowser
  alias MyHiFi.Settings

  @countries_key "station_countries"
  @default_countries "NZ"

  @doc """
  The settings key that holds the country list.
  """
  @spec countries_key() :: String.t()
  def countries_key, do: @countries_key

  @doc """
  The countries that a device copies when a person has chosen none.
  """
  @spec default_countries() :: String.t()
  def default_countries, do: @default_countries

  @impl true
  def run(input, _options, _context) do
    countries = input.arguments[:countries] || configured_countries()

    result =
      Enum.reduce(countries, %{written: 0, failed: []}, fn country, acc ->
        case sync_country(country) do
          {:ok, written} -> %{acc | written: acc.written + written}
          {:error, reason} -> %{acc | failed: [{country, reason} | acc.failed]}
        end
      end)

    Logger.info(
      "Station sync wrote #{result.written} stations from #{inspect(countries)}. " <>
        "#{length(result.failed)} countries failed."
    )

    {:ok, %{written: result.written, failed: Enum.reverse(result.failed), countries: countries}}
  end

  @doc """
  Read the country list from the settings.

  It gives the default when a person has chosen none.
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
        |> Enum.count(&write_station/1)

      {:ok, written}
    end
  end

  defp write_station(attributes) do
    case Radio.upsert_station_from_remote(attributes) do
      {:ok, _station} ->
        true

      {:error, reason} ->
        Logger.warning("Skipped #{attributes.title}: #{Exception.message(reason)}")
        false
    end
  end

  # The service holds stations with no address and stations with no name. Neither
  # can play, and `Station` refuses both.
  defp playable?(%{stream_url: url, title: title})
       when is_binary(url) and url != "" and is_binary(title) and title != "",
       do: true

  defp playable?(_attributes), do: false
end
