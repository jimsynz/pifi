defmodule MyHiFi.Radio.RadioBrowser do
  @moduledoc """
  Reads the station list from the public Radio Browser service.

  See <https://api.radio-browser.info>. The service asks each caller to name
  itself, so each request carries a `User-Agent` header.

  The device copies one country at a time, because the whole list is large and a
  person listens to the radio of one or two countries. The New Zealand list has
  242 stations, and it is 280 KB of JSON.
  """

  @base_url "https://all.api.radio-browser.info"
  @user_agent "MyHiFi/0.1 (+https://harton.dev/mypihifiguy/myhifi)"
  @timeout :timer.seconds(30)

  @doc """
  Ask the service for each station of one country.

  The `country_code` is two letters, such as `NZ`.
  """
  @spec stations_by_country(String.t()) :: {:ok, [map()]} | {:error, term()}
  def stations_by_country(country_code) do
    path = "/json/stations/bycountrycodeexact/#{country_code}"

    case request(path) do
      {:ok, %{status: 200, body: stations}} when is_list(stations) ->
        {:ok, Enum.map(stations, &to_station/1)}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Turn one station of the service into the attributes of `MyHiFi.Radio.Station`.

  `url_resolved` comes first, because the service follows each redirect for us and
  gives the address that plays. `url` is the address that a person gave, and it
  may redirect.
  """
  @spec to_station(map()) :: map()
  def to_station(station) do
    %{
      remote_id: station["stationuuid"],
      title: String.trim(station["name"] || ""),
      stream_url: station["url_resolved"] || station["url"],
      codec: station["codec"],
      bitrate: station["bitrate"],
      hls?: station["hls"] == 1,
      country_code: station["countrycode"],
      language: station["language"],
      tags: parse_tags(station["tags"]),
      artwork_url: presence(station["favicon"]),
      click_count: station["clickcount"] || 0
    }
  end

  # A test gives a stub with `config :my_hi_fi, MyHiFi.Radio.RadioBrowser, plug: ...`.
  # Nothing sets this in production.
  defp request(path) do
    [
      base_url: @base_url,
      url: path,
      headers: [{"user-agent", @user_agent}],
      receive_timeout: @timeout,
      retry: :transient
    ]
    |> Keyword.merge(Application.get_env(:my_hi_fi, __MODULE__, []))
    |> Req.new()
    |> Req.get()
  end

  # The service gives the tags as one string with commas between them.
  defp parse_tags(nil), do: []

  defp parse_tags(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value
end
