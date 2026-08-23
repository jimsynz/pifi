defmodule MyHiFi.Podcast.Index do
  @moduledoc """
  Reads the Podcast Index.

  See <https://podcastindex.org>. The index finds a show, and the feed of the
  publisher gives the episodes. See `MyHiFi.Podcast.Feed`. Nothing that plays
  depends on this module, so a person keeps listening when the index does not
  answer.

  ## The key

  The index asks each caller for a key and a secret, and it gives both at
  <https://api.podcastindex.org/signup> for no money. Each device holds its own,
  in `MyHiFi.Settings`, so no firmware image holds a secret and no two devices
  share a rate limit. A device with no key gives `{:error, :no_api_key}`, and the
  browse page shows that as a message with the address of the signup page.

  Four headers carry the key. `Authorization` is
  `sha1(key <> secret <> date)` as lower case hexadecimal, so `:crypto` gives it
  and this needs no package.

  ## The clock

  `X-Auth-Date` holds a 3 minute window. A board with no battery starts in 1970,
  so a request before the first NTP synchronisation always fails. This asks
  `nerves_time` first and gives `{:error, :clock_not_synchronised}`, because a 401
  tells a person nothing about the cause.
  """

  alias MyHiFi.Settings

  @base_url "https://api.podcastindex.org/api/1.0"
  @default_limit 40
  @key_setting "podcast_index_key"
  @secret_setting "podcast_index_secret"
  @timeout :timer.seconds(30)
  @user_agent "MyHiFi/0.1"

  @typedoc """
  One show, in the shape that `MyHiFi.Podcast.Show` accepts.

  `upsert_from_index` of that resource takes this map as it is.
  """
  @type show :: %{
          feed_url: String.t(),
          index_id: integer(),
          title: String.t(),
          author: String.t() | nil,
          description: String.t() | nil,
          artwork_url: String.t() | nil
        }

  @typedoc "One category of the index."
  @type category :: %{id: integer(), name: String.t()}

  @doc """
  The settings key that holds the key of the index.

  The settings page writes it. This module names it, so no page holds the string.
  """
  @spec key_setting() :: String.t()
  def key_setting, do: @key_setting

  @doc "The settings key that holds the secret of the index."
  @spec secret_setting() :: String.t()
  def secret_setting, do: @secret_setting

  @doc """
  Does this device hold a key?

  The browse page asks this before it shows a search field, so a person reads a
  message about the signup page instead of an error.
  """
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _key, _secret}, credentials())

  @doc """
  Find a show by its title, by its author, or by its owner.

  `:limit` is how many to give, and it becomes 40.
  """
  @spec search(String.t(), keyword()) :: {:ok, [show()]} | {:error, term()}
  def search(query, options \\ []) do
    with {:ok, body} <-
           request("/search/byterm", q: query, max: limit(options)) do
      {:ok, shows(body)}
    end
  end

  @doc """
  Read one show by the address of its feed.

  A person who names a feed gets its title and its artwork before the device reads
  the feed.

  It gives `{:error, :not_in_index}` for a feed that the index does not hold, and a
  private feed is always one of those. `MyHiFi.Podcast.Feed` reads such a feed
  itself, so this error stops nothing.
  """
  @spec show_by_feed_url(String.t()) :: {:ok, show()} | {:error, term()}
  def show_by_feed_url(url) do
    case request("/podcasts/byfeedurl", url: url) do
      {:ok, body} ->
        case show(body["feed"]) do
          nil -> {:error, :not_in_index}
          show -> {:ok, show}
        end

      # The index answers 400 for a feed that it does not hold, and not 200 with an
      # empty feed. A read against the real service on 2026-08-23 gave that. A
      # caller must read it as an absence and not as a fault, because a private
      # feed is never in the index and `MyHiFi.Podcast.Feed` reads one itself.
      {:error, {:unexpected_status, 400}} ->
        {:error, :not_in_index}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The shows that are popular now.

  `:category` names one category of `categories/0`, and it gives the popular shows
  of that category alone. `:language` becomes `en`, because this firmware speaks
  one language today.

  The browse page asks for one category at a time, and only when a person opens it,
  because the index publishes no rate limit.
  """
  @spec trending(keyword()) :: {:ok, [show()]} | {:error, term()}
  def trending(options \\ []) do
    query = [
      max: limit(options),
      lang: Keyword.get(options, :language, "en"),
      cat: Keyword.get(options, :category)
    ]

    with {:ok, body} <- request("/podcasts/trending", query) do
      {:ok, shows(body)}
    end
  end

  @doc """
  Every category of the index.

  The browse page draws one container for each. The list changes very rarely, so a
  caller may hold it.
  """
  @spec categories() :: {:ok, [category()]} | {:error, term()}
  def categories do
    with {:ok, body} <- request("/categories/list", []) do
      categories =
        body
        |> Map.get("feeds", [])
        |> Enum.map(&%{id: &1["id"], name: &1["name"]})
        |> Enum.reject(&(&1.name in [nil, ""]))
        |> Enum.sort_by(& &1.name)

      {:ok, categories}
    end
  end

  @doc """
  The `Authorization` header of one request.

  The index asks for `sha1(key <> secret <> date)`, as hexadecimal, with two digits
  for each byte and lower case for `a` to `f`. The `date` is the same string that
  `X-Auth-Date` carries.

  This is public because it is the one part of this module that the service
  defines, and a test therefore holds a value that no Elixir code computed. The
  key and the secret below are the example values of the documentation of the
  index.

      iex> signature("UXKCGDSYGUUEVQJSYDZH", "yzJe2eE7XV-3eY576dyRZ6wXyAbndh6LUrCZ8KN|", "1613713388")
      "73a1fffed61c1d30d858beb1fc48f355386449d2"
  """
  @spec signature(String.t(), String.t(), String.t()) :: String.t()
  def signature(key, secret, date) do
    :crypto.hash(:sha, key <> secret <> date) |> Base.encode16(case: :lower)
  end

  @doc """
  Turn one feed of the index into the attributes of `MyHiFi.Podcast.Show`.

  It gives `nil` for a feed with no address and for one with no title, because
  neither one can become a row. `artwork` comes before `image`, because the index
  calls the first one the best picture that it holds.
  """
  @spec show(map() | nil) :: show() | nil
  def show(%{"url" => url, "title" => title} = feed) do
    with url when is_binary(url) <- presence(url),
         title when is_binary(title) <- presence(title) do
      %{
        feed_url: url,
        index_id: feed["id"],
        title: title,
        author: presence(feed["author"]) || presence(feed["ownerName"]),
        description: presence(feed["description"]),
        artwork_url: presence(feed["artwork"]) || presence(feed["image"])
      }
    else
      _other -> nil
    end
  end

  def show(_feed), do: nil

  defp shows(body) do
    body
    |> Map.get("feeds", [])
    |> Enum.map(&show/1)
    |> Enum.reject(&is_nil/1)
  end

  # A test gives a stub with `config :my_hi_fi, MyHiFi.Podcast.Index, plug: ...`,
  # in the same way that `MyHiFi.Radio.RadioBrowser` takes one. Nothing sets this
  # in production.
  defp request(path, query) do
    with :ok <- check_clock(),
         {:ok, key, secret} <- credentials() do
      [
        base_url: @base_url,
        url: path,
        params: Enum.reject(query, fn {_name, value} -> value == nil end),
        headers: headers(key, secret),
        receive_timeout: @timeout,
        retry: :transient
      ]
      |> Keyword.merge(Application.get_env(:my_hi_fi, __MODULE__, []))
      |> Req.new()
      |> Req.get()
      |> answer()
    end
  end

  defp answer({:ok, %{status: 200, body: body}}) when is_map(body), do: {:ok, body}
  defp answer({:ok, %{status: 401}}), do: {:error, :key_refused}
  defp answer({:ok, %{status: status}}), do: {:error, {:unexpected_status, status}}
  defp answer({:error, exception}), do: {:error, exception}

  # The index holds a window of 3 minutes for this date, so it comes from the clock
  # of the device at each request and no caller may give it.
  defp headers(key, secret) do
    date = Integer.to_string(System.os_time(:second))

    [
      {"user-agent", @user_agent},
      {"x-auth-key", key},
      {"x-auth-date", date},
      {"authorization", signature(key, secret, date)}
    ]
  end

  # No check for a blank key belongs here. `MyHiFi.Settings.Setting` removes the
  # space around a value and refuses one that then holds nothing, so a stored key
  # always holds a character. A test covers that.
  defp credentials do
    with {:ok, %{value: key}} <- Settings.fetch(@key_setting),
         {:ok, %{value: secret}} <- Settings.fetch(@secret_setting) do
      {:ok, key, secret}
    else
      _other -> {:error, :no_api_key}
    end
  end

  # `nerves_time` is a target dependency, so the host build must hold no reference
  # to it. The host of a developer holds a clock that another program keeps right.
  if Mix.target() == :host do
    defp check_clock, do: :ok
  else
    defp check_clock do
      if NervesTime.synchronized?(), do: :ok, else: {:error, :clock_not_synchronised}
    end
  end

  defp limit(options), do: Keyword.get(options, :limit, @default_limit)

  defp presence(nil), do: nil

  defp presence(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_other), do: nil
end
