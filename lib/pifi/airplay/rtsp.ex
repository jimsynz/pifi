defmodule PiFi.AirPlay.Rtsp do
  @moduledoc """
  Reads and writes the messages that AirPlay's control channel carries.

  **It looks like HTTP and it is not HTTP.** The shape is the same — a request line,
  headers, a blank line and a body — and the differences are what make a plain HTTP
  server the wrong thing to reach for:

  - The methods are RTSP's: `SETUP`, `RECORD`, `FLUSH`, `TEARDOWN`, `GET_PARAMETER` and
    `SET_PARAMETER`, beside the `POST` and `GET` that pairing uses.
  - The version is `RTSP/1.0` on the control channel and `HTTP/1.1` on the pairing
    requests, and a telephone sends both down one socket.
  - **A request carries `CSeq` and a reply has to send the same one back.** A sender
    matches replies to requests by that number and by nothing else, so a reply that
    dropped it is a reply that never arrives as far as the telephone is concerned.

  ## It reads from a stream, so it says when there is not enough yet

  A socket hands over whatever arrived. `parse/1` answers `:more` for a message that has
  not finished arriving, and gives back what is left over when one has, because two
  requests can turn up in one read.

  ## It refuses rather than guessing

  Every byte of this arrives over a network before anything has been authenticated. A
  request line that is not three words, a `Content-Length` that is not a number, a body
  longer than this device is prepared to hold: each is an error and none is a guess.
  """

  @max_body 1024 * 1024

  defmodule Request do
    @moduledoc "One message from a sender."

    @type t :: %__MODULE__{
            method: String.t(),
            uri: String.t(),
            version: String.t(),
            headers: %{String.t() => String.t()},
            body: binary()
          }

    defstruct method: nil, uri: nil, version: nil, headers: %{}, body: <<>>
  end

  @doc """
  Take one request out of what has arrived.

  `{:more, buffer}` means it has not all turned up yet, and the caller reads again.

      iex> PiFi.AirPlay.Rtsp.parse("GET /info RTSP/1.0\\r\\nCSeq: 1\\r\\n\\r\\n")
      {:ok, %PiFi.AirPlay.Rtsp.Request{method: "GET", uri: "/info", version: "RTSP/1.0", headers: %{"cseq" => "1"}, body: ""}, ""}

      iex> PiFi.AirPlay.Rtsp.parse("GET /info RTSP/1.0\\r\\n")
      {:more, "GET /info RTSP/1.0\\r\\n"}
  """
  @spec parse(binary()) :: {:ok, Request.t(), binary()} | {:more, binary()} | {:error, term()}
  def parse(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [_head] -> {:more, buffer}
      [head, rest] -> headed(head, rest, buffer)
    end
  end

  @doc """
  Build a reply.

  **`CSeq` comes from the request**, and `reply_to/3` is there so that no caller has to
  remember to copy it.

      iex> PiFi.AirPlay.Rtsp.response(200, %{"content-type" => "application/octet-stream"}, "hi")
      "RTSP/1.0 200 OK\\r\\ncontent-length: 2\\r\\ncontent-type: application/octet-stream\\r\\n\\r\\nhi"
  """
  @spec response(pos_integer(), %{String.t() => String.t()}, binary(), String.t()) :: binary()
  def response(status, headers, body \\ <<>>, version \\ "RTSP/1.0") do
    lines =
      headers
      |> Map.put("content-length", to_string(byte_size(body)))
      |> Enum.sort()
      |> Enum.map_join("", fn {name, value} -> "#{name}: #{value}\r\n" end)

    "#{version} #{status} #{reason(status)}\r\n#{lines}\r\n#{body}"
  end

  @doc """
  Build a reply that answers one request, carrying its `CSeq` back.

  **A sender matches replies to requests by that number and by nothing else**, so a
  reply without it is one the telephone never sees.
  """
  @spec reply_to(Request.t(), pos_integer(), %{String.t() => String.t()}, binary()) :: binary()
  def reply_to(%Request{} = request, status, headers \\ %{}, body \\ <<>>) do
    headers =
      case Map.fetch(request.headers, "cseq") do
        {:ok, cseq} -> Map.put(headers, "cseq", cseq)
        :error -> headers
      end

    response(status, headers, body, request.version)
  end

  @doc """
  One header of a request, by name, whatever case it arrived in.

      iex> {:ok, request, ""} = PiFi.AirPlay.Rtsp.parse("GET / RTSP/1.0\\r\\nCSeq: 7\\r\\n\\r\\n")
      iex> PiFi.AirPlay.Rtsp.header(request, "cseq")
      {:ok, "7"}
  """
  @spec header(Request.t(), String.t()) :: {:ok, String.t()} | :error
  def header(%Request{headers: headers}, name), do: Map.fetch(headers, String.downcase(name))

  defp headed(head, rest, buffer) do
    with [request_line | header_lines] <- String.split(head, "\r\n"),
         {:ok, method, uri, version} <- request_line(request_line),
         {:ok, headers} <- headers(header_lines),
         {:ok, length} <- content_length(headers) do
      bodied(
        %Request{method: method, uri: uri, version: version, headers: headers},
        length,
        rest,
        buffer
      )
    end
  end

  defp request_line(line) do
    case String.split(line, " ", parts: 3) do
      [method, uri, version] -> {:ok, method, uri, version}
      _other -> {:error, {:bad_request_line, line}}
    end
  end

  # **A header name arrives in whatever case a sender felt like.** `CSeq`, `cseq` and
  # `CSEQ` are one header, so they are compared in one case and never as they arrived.
  defp headers(lines) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, found} ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> {:cont, {:ok, Map.put(found, String.downcase(name), String.trim(value))}}
        _other -> {:halt, {:error, {:bad_header, line}}}
      end
    end)
  end

  defp content_length(headers) do
    case Map.fetch(headers, "content-length") do
      :error ->
        {:ok, 0}

      {:ok, value} ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 and length <= @max_body -> {:ok, length}
          {length, ""} when length > @max_body -> {:error, {:body_too_large, length}}
          _other -> {:error, {:bad_content_length, value}}
        end
    end
  end

  defp bodied(%Request{} = request, 0, rest, _buffer), do: {:ok, request, rest}

  defp bodied(%Request{} = request, length, rest, _buffer) when byte_size(rest) >= length do
    <<body::binary-size(^length), remainder::binary>> = rest

    {:ok, %Request{request | body: body}, remainder}
  end

  defp bodied(%Request{}, _length, _rest, buffer), do: {:more, buffer}

  defp reason(200), do: "OK"
  defp reason(400), do: "Bad Request"
  defp reason(401), do: "Unauthorized"
  defp reason(403), do: "Forbidden"
  defp reason(404), do: "Not Found"
  defp reason(453), do: "Not Enough Bandwidth"
  defp reason(500), do: "Internal Server Error"
  defp reason(_status), do: "Error"
end
