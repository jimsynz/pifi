defmodule MyHiFi.Podcast.Feed.Parser do
  @moduledoc """
  Reads a podcast feed, one chunk at a time.

  A caller gives the bytes as they arrive and gets a show and its episodes. It
  holds no copy of the document, so a large feed needs little memory. Of the 50
  most popular New Zealand podcasts, the median feed is 1.6 MB and the largest is
  13.6 MB.

      {:ok, parser} = Parser.new()
      {:cont, parser} = Parser.feed(parser, chunk)
      {:ok, feed} = Parser.finish(parser)

  `feed/2` gives `{:done, feed}` when it holds enough episodes. A caller then stops
  the download and calls `finish/1` no more.

  This reads RSS 2.0 alone, because Apple asks each publisher for RSS 2.0 and
  every one of those 50 feeds sends it. An Atom document gives
  `{:error, :not_rss}`.

  It reads these elements, and it steps over every other one at no cost:

      channel   title, description, itunes:author, itunes:image, image/url
      item      title, guid, pubDate, description, itunes:subtitle,
                itunes:duration, itunes:image, enclosure

  It also reads the two formats that a feed writes a date and a length in. See
  `published_at/1` and `duration_ms/1`.

  A prefix other than `itunes` for that namespace is legal, and no feed of the
  measurement uses one. Such a feed loses the artwork and the length of an
  episode, and it keeps the title, the date and the audio.
  """

  @behaviour Saxy.Handler

  @default_max_items 200

  # A description holds text that a person wrote, and 32 KB is far more than a
  # person writes. Some feeds hold an image inside the description as base64, and
  # 200 of those would end the firmware. The reader therefore stops at this size
  # and keeps what it holds.
  @max_text_bytes 32 * 1024

  @months %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  # RFC 2822 section 4.3 keeps these names, and it asks a reader to accept them.
  # It also asks a reader to treat every other name as an unknown offset, which is
  # zero.
  @zones %{
    "ut" => 0,
    "utc" => 0,
    "gmt" => 0,
    "z" => 0,
    "est" => -5,
    "edt" => -4,
    "cst" => -6,
    "cdt" => -5,
    "mst" => -7,
    "mdt" => -6,
    "pst" => -8,
    "pdt" => -7
  }

  @rfc2822 ~r/^(?:[A-Za-z]{3},\s*)?(?<day>\d{1,2})\s+(?<month>[A-Za-z]{3})[a-z]*\s+(?<year>\d{2,4})\s+(?<hour>\d{1,2}):(?<minute>\d{2})(?::(?<second>\d{2}))?(?:\s+(?<zone>[+-]\d{4}|[A-Za-z]+))?/

  @typedoc "One show, as the channel of the feed describes it."
  @type show :: %{
          title: String.t() | nil,
          description: String.t() | nil,
          author: String.t() | nil,
          artwork_url: String.t() | nil
        }

  @typedoc """
  One episode.

  `duration_ms` and `published_at` are `nil` for an element that the feed does not
  hold, and for one that it writes in a form that no reader knows.
  """
  @type episode :: %{
          guid: String.t(),
          title: String.t() | nil,
          subtitle: String.t() | nil,
          description: String.t() | nil,
          audio_url: String.t(),
          mime_type: String.t() | nil,
          byte_length: pos_integer() | nil,
          duration_ms: pos_integer() | nil,
          published_at: DateTime.t() | nil,
          artwork_url: String.t() | nil
        }

  @typedoc "The show, and its episodes with the newest one first."
  @type feed :: %{show: show(), episodes: [episode()]}

  defmodule State do
    @moduledoc false

    defstruct path: [],
              rss?: false,
              capture: nil,
              text: nil,
              show: %{},
              episode: nil,
              episodes: [],
              count: 0,
              max_items: 200
  end

  @doc """
  Start a reader.

  `:max_items` is how many episodes to keep, and it becomes 200. A feed writes the
  newest episode first, so the reader keeps the newest ones. One feed of the
  measurement holds 2955 episodes, and no person moves through that with a knob.
  """
  @spec new(keyword()) :: {:ok, Saxy.Partial.t()} | {:error, Saxy.ParseError.t()}
  def new(options \\ []) do
    state = %State{max_items: Keyword.get(options, :max_items, @default_max_items)}

    Saxy.Partial.new(__MODULE__, state)
  end

  @doc """
  Give the reader the next chunk of the feed.

  `{:done, feed}` means that the reader holds `:max_items` episodes. Stop the
  download: the rest of the feed holds older episodes, and this gives the answer
  already.
  """
  @spec feed(Saxy.Partial.t(), binary()) ::
          {:cont, Saxy.Partial.t()} | {:done, feed()} | {:error, term()}
  def feed(partial, chunk) do
    case Saxy.Partial.parse(partial, chunk) do
      {:cont, partial} -> {:cont, partial}
      {:halt, %State{} = state} -> stopped(state)
      {:halt, %State{} = state, _rest} -> stopped(state)
      {:error, exception} -> {:error, exception}
    end
  end

  @doc """
  Close the reader and give the show and the episodes.

  A document that stops in the middle gives an error, so a download that fails
  cannot give half of a feed.
  """
  @spec finish(Saxy.Partial.t()) :: {:ok, feed()} | {:error, term()}
  def finish(partial) do
    case Saxy.Partial.terminate(partial) do
      {:ok, %State{} = state} -> done(state)
      {:error, exception} -> {:error, exception}
    end
  end

  @doc """
  Read the date of an episode.

  A feed writes an RFC 2822 date, such as `Thu, 02 Jun 2022 14:00:00 -0500`. The
  day name is optional, the seconds are optional, and the zone is a numeric offset
  or one of the names of RFC 2822 section 4.3. Every other name gives an unknown
  offset, which that section reads as zero.

      iex> published_at("Thu, 02 Jun 2022 14:00:00 -0500")
      ~U[2022-06-02 19:00:00Z]

      iex> published_at("3 Mar 2025 09:05 GMT")
      ~U[2025-03-03 09:05:00Z]

      iex> published_at("some time last week")
      nil
  """
  @spec published_at(String.t()) :: DateTime.t() | nil
  def published_at(text) do
    with %{"day" => day, "month" => month, "year" => year, "hour" => hour, "minute" => minute} =
           parts <- Regex.named_captures(@rfc2822, String.trim(text)),
         {:ok, month} <- Map.fetch(@months, String.downcase(month)),
         {:ok, date} <- Date.new(year(year), month, String.to_integer(day)),
         {:ok, time} <-
           Time.new(String.to_integer(hour), String.to_integer(minute), second(parts["second"])) do
      date
      |> DateTime.new!(time)
      |> DateTime.add(-offset(parts["zone"]), :second)
    else
      _other -> nil
    end
  end

  @doc """
  Read the length of an episode.

  A feed writes `itunes:duration` as whole seconds, as minutes and seconds, or as
  hours, minutes and seconds. All three appear in the measurement.

      iex> duration_ms("2921")
      2_921_000

      iex> duration_ms("48:41")
      2_921_000

      iex> duration_ms("01:02:13")
      3_733_000

      iex> duration_ms("")
      nil
  """
  @spec duration_ms(String.t()) :: pos_integer() | nil
  def duration_ms(text) do
    text
    |> String.trim()
    |> String.split(":")
    |> Enum.map(&Integer.parse/1)
    |> seconds()
    |> case do
      nil -> nil
      0 -> nil
      seconds -> seconds * 1000
    end
  end

  @impl Saxy.Handler
  def handle_event(event, data, state)

  # The root element decides whether this is a feed that we read. An Atom document
  # holds `feed`, and an error page holds `html`, and neither one holds an
  # enclosure.
  def handle_event(:start_element, {"rss", _attributes}, %State{path: []} = state) do
    {:ok, %State{state | rss?: true, path: ["rss"]}}
  end

  def handle_event(:start_element, _element, %State{rss?: false, path: []} = state) do
    {:stop, state}
  end

  def handle_event(:start_element, {name, attributes}, %State{} = state) do
    path = [name | state.path]

    {:ok, start(path, attributes, %State{state | path: path})}
  end

  def handle_event(:characters, chars, %State{text: text} = state) when is_list(text) do
    {:ok, %State{state | text: append(text, chars)}}
  end

  def handle_event(:end_element, "item", %State{path: ["item", "channel", "rss"]} = state) do
    close_item(%State{state | path: ["channel", "rss"], capture: nil, text: nil})
  end

  # The element that started the capture is the one that ends it. A captured
  # element can hold another element, and the text of the inner one belongs to the
  # outer one. Some feeds write the show notes of an episode as XHTML inside
  # `<description>`.
  def handle_event(:end_element, _name, %State{path: path, capture: path} = state) do
    [_name | rest] = path

    {:ok, %State{store(state) | path: rest, capture: nil, text: nil}}
  end

  def handle_event(:end_element, _name, %State{} = state) do
    [_name | path] = state.path

    {:ok, %State{state | path: path}}
  end

  def handle_event(_event, _data, %State{} = state), do: {:ok, state}

  # An element with a value in an attribute needs no text, so it is read here and
  # not at its end.
  defp start(["enclosure", "item", "channel", "rss"], attributes, state) do
    put(state, :episode, :audio_url, presence(attribute(attributes, "url")))
    |> put(:episode, :mime_type, presence(attribute(attributes, "type")))
    |> put(:episode, :byte_length, bytes(attribute(attributes, "length")))
  end

  defp start(["itunes:image", "item", "channel", "rss"], attributes, state) do
    put(state, :episode, :artwork_url, presence(attribute(attributes, "href")))
  end

  defp start(["itunes:image", "channel", "rss"], attributes, state) do
    put(state, :show, :artwork_url, presence(attribute(attributes, "href")))
  end

  defp start(["item", "channel", "rss"], _attributes, %State{} = state) do
    %State{state | episode: %{}}
  end

  # Nothing accumulates the text of an element that this firmware does not read, so
  # a long element costs nothing. An element inside a captured one also adds
  # nothing here, because the capture belongs to the outer element.
  defp start(_path, _attributes, %State{capture: capture} = state) when capture != nil, do: state

  defp start(path, _attributes, %State{} = state) do
    case field(path) do
      nil -> state
      _field -> %State{state | capture: path, text: []}
    end
  end

  # Which paths hold a value that this firmware reads. The whole path decides,
  # because `<image><title>` of a channel is not the title of the show.
  defp field(["title", "channel", "rss"]), do: {:show, :title}
  defp field(["description", "channel", "rss"]), do: {:show, :description}
  defp field(["itunes:author", "channel", "rss"]), do: {:show, :author}
  defp field(["url", "image", "channel", "rss"]), do: {:show, :rss_artwork_url}
  defp field(["title", "item", "channel", "rss"]), do: {:episode, :title}
  defp field(["guid", "item", "channel", "rss"]), do: {:episode, :guid}
  defp field(["pubDate", "item", "channel", "rss"]), do: {:episode, :published_at}
  defp field(["description", "item", "channel", "rss"]), do: {:episode, :description}
  defp field(["itunes:subtitle", "item", "channel", "rss"]), do: {:episode, :subtitle}
  defp field(["itunes:duration", "item", "channel", "rss"]), do: {:episode, :duration_ms}
  defp field(_path), do: nil

  defp store(%State{text: nil} = state), do: state

  defp store(%State{text: text} = state) do
    {target, key} = field(state.path)

    put(state, target, key, value(key, IO.iodata_to_binary(text)))
  end

  defp value(:published_at, text), do: published_at(text)
  defp value(:duration_ms, text), do: duration_ms(text)
  defp value(_key, text), do: presence(text)

  # An episode with no audio cannot play, so it never reaches the database. A feed
  # holds such an item for a post that carries text alone.
  #
  # A `guid` is not compulsory, and the address of the audio identifies an episode
  # when the feed gives no `guid`.
  defp close_item(%State{episode: %{audio_url: url} = episode} = state)
       when is_binary(url) do
    episode = Map.put_new(episode, :guid, url)
    count = state.count + 1

    state = %State{
      state
      | episode: nil,
        episodes: [episode | state.episodes],
        count: count
    }

    if count >= state.max_items do
      {:stop, state}
    else
      {:ok, state}
    end
  end

  defp close_item(%State{} = state), do: {:ok, %State{state | episode: nil}}

  defp stopped(%State{} = state) do
    case done(state) do
      {:ok, feed} -> {:done, feed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp done(%State{rss?: false}), do: {:error, :not_rss}

  defp done(%State{} = state) do
    {:ok,
     %{
       show: %{
         title: state.show[:title],
         description: state.show[:description],
         author: state.show[:author],
         # `itunes:image` is what Apple asks a publisher for, and it holds the
         # larger picture. `<image><url>` is the element of RSS 2.0, and a feed can
         # hold either one before the other, so the choice happens here and not
         # where each one arrives.
         artwork_url: state.show[:artwork_url] || state.show[:rss_artwork_url]
       },
       episodes: state.episodes |> Enum.reverse() |> Enum.map(&episode/1)
     }}
  end

  defp episode(episode) do
    %{
      guid: episode.guid,
      title: episode[:title],
      subtitle: episode[:subtitle],
      description: episode[:description],
      audio_url: episode.audio_url,
      mime_type: episode[:mime_type],
      byte_length: episode[:byte_length],
      duration_ms: episode[:duration_ms],
      published_at: episode[:published_at],
      artwork_url: episode[:artwork_url]
    }
  end

  defp put(%State{episode: nil} = state, :episode, _key, _value), do: state
  defp put(%State{} = state, _target, _key, nil), do: state

  defp put(%State{} = state, :show, key, value) do
    %State{state | show: Map.put(state.show, key, value)}
  end

  defp put(%State{} = state, :episode, key, value) do
    %State{state | episode: Map.put(state.episode, key, value)}
  end

  defp append(text, chars) do
    if IO.iodata_length(text) >= @max_text_bytes, do: text, else: [text | chars]
  end

  defp attribute(attributes, name) do
    case List.keyfind(attributes, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp bytes(nil), do: nil

  defp bytes(text) do
    case Integer.parse(String.trim(text)) do
      {length, _rest} when length > 0 -> length
      _other -> nil
    end
  end

  defp seconds([{seconds, _}]), do: seconds
  defp seconds([{minutes, _}, {seconds, _}]), do: minutes * 60 + seconds

  defp seconds([{hours, _}, {minutes, _}, {seconds, _}]),
    do: hours * 3600 + minutes * 60 + seconds

  defp seconds(_other), do: nil

  defp second(""), do: 0
  defp second(text), do: String.to_integer(text)

  # RFC 2822 section 4.3 reads a year of two digits, and it puts 50 and above in
  # the last century.
  defp year(text) do
    case String.to_integer(text) do
      year when year < 50 -> year + 2000
      year when year < 100 -> year + 1900
      year -> year
    end
  end

  defp offset(""), do: 0

  defp offset(<<sign, hours::binary-2, minutes::binary-2>>) when sign in [?+, ?-] do
    seconds = String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60

    if sign == ?-, do: -seconds, else: seconds
  end

  defp offset(name), do: Map.get(@zones, String.downcase(name), 0) * 3600

  defp presence(nil), do: nil

  defp presence(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
