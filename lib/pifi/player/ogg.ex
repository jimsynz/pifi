defmodule PiFi.Player.Ogg do
  @moduledoc """
  Says which codec an Ogg stream carries.

  Ogg is a container, and it carries Vorbis, FLAC, Opus or Speex. Radio Browser
  reports the codec `OGG` for each one, so the table cannot say which. Of the 6
  New Zealand stations that send Ogg, 3 hold Vorbis and 3 hold FLAC, and two of
  the FLAC ones name FLAC in their title and `OGG` in their codec.

  The first page of the stream names the codec. Each codec writes an
  identification header at the start of that page:

      \\x01vorbis     Vorbis
      \\x7FFLAC       FLAC
      OpusHead       Opus
      Speex          Speex

  One program cannot serve all of them over a pipe. `ogg123` names FLAC, Speex,
  Opus and Vorbis among its codecs, and it reads a file to find out which one it
  carries. Reading from a pipe it cannot go back to the start, so it takes the first
  module that it tries and stops with "Error opening - using the oggvorbis module"
  on a FLAC stream. Each codec therefore needs its own program, and that needs this
  module.
  """

  @type codec :: :vorbis | :flac | :opus | :speex

  # The first page of an Ogg stream carries the identification header, and a page is
  # at most 65307 bytes. The header sits at the start of it.
  @bytes 8192

  @doc """
  Read the first bytes of the stream and name the codec.
  """
  @spec codec(String.t()) :: {:ok, codec()} | {:error, term()}
  def codec(uri) do
    with {:ok, first} <- first_bytes(uri) do
      case name(first) do
        nil -> {:error, :unknown_ogg_codec}
        codec -> {:ok, codec}
      end
    end
  end

  defp name(bytes) do
    cond do
      String.contains?(bytes, <<0x7F, "FLAC">>) -> :flac
      String.contains?(bytes, <<0x01, "vorbis">>) -> :vorbis
      String.contains?(bytes, "OpusHead") -> :opus
      String.contains?(bytes, "Speex") -> :speex
      true -> nil
    end
  end

  # It takes the first bytes and no more. A live stream never ends, so a whole read
  # would never finish.
  defp first_bytes(uri) do
    # `into:` gives the request and the answer so far, and a step adds to the body
    # of that answer itself.
    collect = fn {:data, data}, {request, response} ->
      response = update_in(response.body, &(&1 <> data))

      if byte_size(response.body) >= @bytes do
        {:halt, {request, response}}
      else
        {:cont, {request, response}}
      end
    end

    case Req.get(request(), url: uri, into: collect) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and body != <<>> -> {:ok, body}
      {:ok, %{status: 200}} -> {:error, :no_bytes}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # This module has its own configuration key, and it does not share the one of
  # `PiFi.Player.Hls`. A shared key made two tests fight over one application
  # environment, and one of them lost its stub while it ran.
  defp request do
    :pifi
    |> Application.get_env(__MODULE__, [])
    |> Keyword.put_new(:receive_timeout, :timer.seconds(15))
    |> Keyword.put_new(:retry, false)
    |> Req.new()
  end
end
