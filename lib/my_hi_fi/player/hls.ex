defmodule MyHiFi.Player.Hls do
  @moduledoc """
  Reads an HLS playlist and says how to play it.

  An HLS address gives a playlist and not audio. The player needs three facts
  before it builds a pipeline, and only the playlist names them.

  A **master** playlist names one or more variant streams, and each variant names
  a media playlist. A **media** playlist names the segments. A station address can
  be either one, and 4 of the 44 New Zealand HLS stations give a media playlist.

  The **container** comes from the name of the first segment. A `.ts` segment
  carries MPEG-TS, and the pipeline then needs a demultiplexer. Any other segment
  carries the audio with no container, so the decoder reads it as it arrives.

  The **codec** comes from the `CODECS` attribute of the variant. `mp4a.40.34`
  is MP3, and the other `mp4a` values are AAC. A media playlist carries no such
  attribute, so a caller gives the codec of the station instead.

  A count of the 44 New Zealand stations on 2026-08-22:

      14  master playlist, `.aac` segments, HE-AAC or AAC
      17  master playlist, `.ts` segments, AAC or MP3
       4  media playlist, `.ts` segments
       9  no answer, or a variant that this module reads and the count did not

  `Membrane.HLS.SourceBin` cannot serve this. It reads a variant stream as MPEG-TS
  always, and 14 stations hold no container.
  """

  require Logger

  alias MyHiFi.Player.Hls.Storage

  @type container :: :mpeg_ts | :none
  @type codec :: :aac | :mp3

  @type t :: %{
          media_playlist_uri: URI.t(),
          container: container(),
          format: codec()
        }

  @doc """
  Read the playlist at `uri`.

  `codec` is the codec that the station names, and it applies when the playlist
  names none.
  """
  @spec resolve(String.t(), codec()) :: {:ok, t()} | {:error, term()}
  def resolve(uri, codec) do
    uri = URI.parse(uri)

    with {:ok, body} <- get(uri) do
      if master?(body) do
        resolve_master(body, uri, codec)
      else
        resolve_media(body, uri, codec)
      end
    end
  end

  defp resolve_master(body, uri, codec) do
    with {:ok, variant} <- variant(body, uri),
         media_uri = HLS.Playlist.build_absolute_uri(uri, variant.uri),
         {:ok, media_body} <- get(media_uri) do
      {:ok,
       %{
         media_playlist_uri: media_uri,
         container: container(media_body, media_uri),
         format: codec_of(variant.codecs) || codec
       }}
    end
  end

  defp resolve_media(body, uri, codec) do
    {:ok, %{media_playlist_uri: uri, container: container(body, uri), format: codec}}
  end

  # The lowest bandwidth is enough for radio, and it is kind to a board with one
  # Wi-Fi radio. A radio station names one variant in almost every case.
  defp variant(body, uri) do
    case HLS.Playlist.unmarshal(body, %HLS.Playlist.Master{uri: uri}) do
      %HLS.Playlist.Master{streams: [_first | _rest] = streams} ->
        {:ok, Enum.min_by(streams, &(&1.bandwidth || 0))}

      %HLS.Playlist.Master{} ->
        {:error, :no_variant_stream}
    end
  rescue
    error -> {:error, {:cannot_read_playlist, Exception.message(error)}}
  end

  defp container(body, uri) do
    case first_segment(body, uri) do
      nil ->
        Logger.warning("The playlist at #{uri} names no segment. Reading it as MPEG-TS.")
        :mpeg_ts

      segment ->
        if String.ends_with?(segment, ".ts"), do: :mpeg_ts, else: :none
    end
  end

  defp first_segment(body, uri) do
    case HLS.Playlist.unmarshal(body, %HLS.Playlist.Media{uri: uri}) do
      %HLS.Playlist.Media{segments: [%{uri: segment} | _rest]} -> path_of(segment)
      %HLS.Playlist.Media{} -> nil
    end
  rescue
    _error -> nil
  end

  defp path_of(%URI{path: path}), do: path
  defp path_of(segment) when is_binary(segment), do: segment |> URI.parse() |> Map.get(:path)
  defp path_of(_segment), do: nil

  # `mp4a.40.34` is MPEG-1 Layer 3. Every other `mp4a` profile here is AAC:
  # `.2` is AAC-LC, `.5` is HE-AAC, and `.29` is HE-AAC v2.
  defp codec_of(nil), do: nil

  defp codec_of(codecs) do
    Enum.find_value(codecs, fn
      "mp4a.40.34" -> :mp3
      "mp4a" <> _rest -> :aac
      _other -> nil
    end)
  end

  defp master?(body), do: String.contains?(body, "#EXT-X-STREAM-INF")

  defp get(uri) do
    case Req.get(Storage.request(), url: uri) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:playlist_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
