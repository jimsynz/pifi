defmodule PiFi.Podcast.Feed do
  @moduledoc """
  Reads a podcast feed over HTTP.

  `Req` gives the answer in chunks, and each chunk goes to
  `PiFi.Podcast.Feed.Parser`. Nothing keeps the whole document, so a large feed
  needs little memory. Of the 50 most popular New Zealand podcasts the median feed
  is 1.6 MB and the largest is 13.6 MB.

  It stops the download as soon as it has enough episodes. A feed writes the
  newest episode first, so the rest of the document carries older episodes only. The
  largest feed of the measurement has 2955 episodes, and 200 of them arrive in
  the first 900 KB.

  `Req` decompresses no body that streams into a function, and it therefore asks
  for none. A server that sends one anyway gives
  `{:error, {:unsupported_encoding, encoding}}`, and not a parse error, because a
  reason that names the cause is worth the three lines.
  """

  alias PiFi.Podcast.Feed.Parser

  @accept "application/rss+xml, application/xml, text/xml, */*"
  @max_bytes 32 * 1024 * 1024
  @timeout :timer.seconds(30)
  @user_agent "PiFi/0.1 (+https://harton.dev/mypihifiguy/myhifi)"

  @doc """
  Read the feed at one address.

  It passes each option to `PiFi.Podcast.Feed.Parser.new/1`, so `:max_items`
  belongs here.

  The errors:

  - `{:unexpected_status, status}` for an answer that is not 200. It reads no body,
    so a page that says "not found" costs one request and nothing more.
  - `{:unsupported_encoding, encoding}` for a compressed answer.
  - `:feed_too_large` for a feed above 32 MB. The largest of the measurement is
    13.6 MB.
  - `:not_rss` for an Atom document, and for an answer with no feed.
  - A `Saxy.ParseError` for a document that stops in the middle, so a download that
    fails cannot give half of a feed.
  - Whatever `Req` gives for a network fault.
  """
  @spec read(String.t(), keyword()) :: {:ok, Parser.feed()} | {:error, term()}
  def read(url, options \\ []) do
    with {:ok, parser} <- Parser.new(options) do
      state = %{parser: parser, bytes: 0, result: nil}

      case request(url, state) do
        {:ok, response} -> finish(response)
        {:error, exception} -> {:error, exception}
      end
    end
  end

  # A test gives a stub with `config :pifi, PiFi.Podcast.Feed, plug: ...`, in
  # the same way that `PiFi.Radio.RadioBrowser` takes one. Nothing sets this in
  # production.
  #
  # `retry: false` is not a choice about how much a device should try. A retry runs
  # the collector again, and the parser then keeps the elements of the first try,
  # so the second one gives a parse error. The refresh job is an Oban job with
  # `max_attempts`, and that is the layer that tries again.
  defp request(url, state) do
    [
      url: url,
      headers: [{"user-agent", @user_agent}, {"accept", @accept}],
      receive_timeout: @timeout,
      retry: false,
      into: fn {:data, data}, {request, response} ->
        response = collect(data, response, state)

        case Req.Response.get_private(response, :feed) do
          %{parser: nil} -> {:halt, {request, response}}
          _reading -> {:cont, {request, response}}
        end
      end
    ]
    |> Keyword.merge(Application.get_env(:pifi, __MODULE__, []))
    |> Req.new()
    |> Req.get()
  end

  defp collect(data, response, initial) do
    state = Req.Response.get_private(response, :feed, initial)

    Req.Response.put_private(response, :feed, read_chunk(data, state, response))
  end

  defp read_chunk(_data, %{parser: nil} = state, _response), do: state

  # The status arrives before the body, so a page that says "not found" reaches
  # neither the parser nor the network a second time.
  defp read_chunk(_data, state, %{status: status}) when status != 200 do
    stop(state, {:error, {:unexpected_status, status}})
  end

  # The headers arrive with the status, so the first chunk is where this belongs.
  defp read_chunk(data, %{bytes: 0} = state, response) do
    case Req.Response.get_header(response, "content-encoding") do
      [] -> parse(data, state)
      ["identity"] -> parse(data, state)
      [encoding | _rest] -> stop(state, {:error, {:unsupported_encoding, encoding}})
    end
  end

  defp read_chunk(data, state, _response), do: parse(data, state)

  defp parse(data, %{bytes: bytes} = state) when bytes + byte_size(data) > @max_bytes do
    stop(state, {:error, :feed_too_large})
  end

  defp parse(data, state) do
    case Parser.feed(state.parser, data) do
      {:cont, parser} -> %{state | parser: parser, bytes: state.bytes + byte_size(data)}
      {:done, feed} -> stop(state, {:ok, feed})
      {:error, reason} -> stop(state, {:error, reason})
    end
  end

  # A `nil` parser means that this reader wants no more bytes, and `result` then
  # carries the answer.
  defp stop(state, result), do: %{state | parser: nil, result: result}

  # An answer with no body runs the collector no time at all, so the private value
  # is absent and the status is the only thing to report.
  defp finish(%{status: 200} = response) do
    case Req.Response.get_private(response, :feed) do
      # An answer with no bytes carries no feed, and that is a better reason than the
      # place where an empty document stops.
      %{result: nil, bytes: 0} -> {:error, :not_rss}
      %{result: nil, parser: parser} -> Parser.finish(parser)
      %{result: result} -> result
      nil -> {:error, :not_rss}
    end
  end

  defp finish(%{status: status}), do: {:error, {:unexpected_status, status}}
end
