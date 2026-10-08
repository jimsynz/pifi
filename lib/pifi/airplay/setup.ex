defmodule PiFi.AirPlay.Setup do
  @moduledoc """
  Reads what a sender asks for in `SETUP`, and says what this receiver will give it.

  **`SETUP` happens twice on one connection, and the two messages look nothing alike.**
  The first describes the session and asks where to send events; the second describes
  the audio and asks where to send it. A sender tells them apart by the presence of a
  `streams` array and so does this — there is no field that names the phase.

  ## Nothing here opens a socket

  The ports come in as arguments and go out in the answer. That keeps the whole of this
  readable from a test: hand it the plist a sender sends and check the plist that comes
  back, with no listener and no telephone. Whatever opens the sockets decides the
  numbers and passes them in.

  ## What a realtime stream actually carries

  A sender negotiating the realtime path names `ct` (the compression type), `sr` and
  `spf`, and the evidence collected on the issue is that **it sends ALAC whatever the
  receiver advertises** — one sender hardcodes it and ignores those fields entirely. So
  they are read and reported rather than obeyed, and `PiFi.AirPlay.Alac` refuses a
  stream it cannot decode when the audio starts rather than here. Reporting them is
  still worth it: the first real telephone that connects settles what it really sends,
  and a receiver that threw them away would have nothing to show.

  ## PTP is read and not kept

  `timingProtocol` says PTP for every modern sender, and this receiver reads it, reports
  it, and runs no clock. **PTP exists so that several speakers agree with each other**,
  and one speaker has nothing to agree with: the audio plays as it arrives, and
  `PiFi.AirPlay.Router` reads `SETRATEANCHORTIME` for its `rate` and not for the anchor
  that would place it on a shared clock. A board played from a telephone on 2026-10-08
  with none of it.

  Doing it properly is not a small module. Shairport Sync gave up running IEEE 1588
  in-process and shipped a separate daemon, NQPTP, for it, and the ports are not the
  difficulty — this firmware runs as root — but holding a clock steady enough for a
  group to agree is, on a runtime that schedules as the BEAM does. `SETPEERS`, which is
  the list of the other speakers of a group, is answered and ignored for the same
  reason.

  ## The session key is thirty-two bytes or it is nothing

  `shk` becomes the ChaCha20-Poly1305 key that every audio packet is decrypted with, so
  a key of any other length is refused here. Shairport Sync learned this one the same
  way: a short key read past its end on every packet.
  """

  alias PiFi.AirPlay.BinaryPlist

  @realtime 96
  @buffered 103
  @remote_control 130

  @key_bytes 32

  @typedoc "Which of the two `SETUP` messages arrived."
  @type phase :: {:session, session()} | {:streams, [stream()]}

  @typedoc "The first `SETUP`, which describes the connection."
  @type session :: %{
          name: String.t() | nil,
          timing: :ptp | :ntp | :none,
          remote_control_only?: boolean()
        }

  @typedoc "One entry of the `streams` array of the second `SETUP`."
  @type stream :: %{
          kind: :realtime | :buffered | :remote_control,
          key: binary() | nil,
          compression: non_neg_integer() | nil,
          sample_rate: pos_integer() | nil,
          frames_per_packet: pos_integer() | nil
        }

  @doc """
  Read a `SETUP` body, and say which of the two messages it is.

  A body with no `streams` array is the first one.

      iex> body = PiFi.AirPlay.BinaryPlist.encode(%{
      ...>   "name" => "A telephone",
      ...>   "timingProtocol" => "PTP"
      ...> })
      iex> PiFi.AirPlay.Setup.read(body)
      {:ok, {:session, %{name: "A telephone", timing: :ptp, remote_control_only?: false}}}

  A body that carries one is the second.

      iex> body = PiFi.AirPlay.BinaryPlist.encode(%{
      ...>   "streams" => [%{"type" => 96, "sr" => 44100, "spf" => 352}]
      ...> })
      iex> {:ok, {:streams, [stream]}} = PiFi.AirPlay.Setup.read(body)
      iex> {stream.kind, stream.sample_rate, stream.frames_per_packet}
      {:realtime, 44100, 352}
  """
  @spec read(binary()) :: {:ok, phase()} | {:error, term()}
  def read(body) when is_binary(body) do
    with {:ok, plist} <- BinaryPlist.decode(body) do
      case plist do
        %{"streams" => streams} when is_list(streams) -> streams(streams)
        %{} = plist -> {:ok, {:session, session(plist)}}
        _other -> {:error, :not_a_dictionary}
      end
    end
  end

  @doc """
  The answer to the first `SETUP`.

  `event_port` is the TCP port this receiver listens on for the event channel. **It
  carries no metadata, and the reason is the feature bits.** With bit 50 set a sender
  posts the title, the artist and the artwork to `/command` as a binary plist and sends
  nothing at all down this channel, so it is opened and accepted because a sender that
  found nothing listening would abandon the session, and for no other reason. See
  `PiFi.AirPlay.NowPlaying`.

  **`timingPort` is zero on purpose for PTP.** The timing of a PTP session happens on
  the two well-known ports of IEEE 1588 rather than on one this receiver chooses, so
  there is no number to give and every receiver sends zero here.

      iex> PiFi.AirPlay.Setup.session_reply(7_000)
      %{"eventPort" => 7000, "timingPort" => 0}
  """
  @spec session_reply(:inet.port_number()) :: %{String.t() => term()}
  def session_reply(event_port) do
    %{"eventPort" => event_port, "timingPort" => 0}
  end

  @doc """
  The answer to the second `SETUP`, one entry for each stream that was asked for.

  `ports` says which port to name for each kind. A realtime stream gets a UDP port for
  the audio and one for control; a buffered stream gets a TCP port and is told how much
  this receiver will hold.

      iex> streams = [%{kind: :realtime, key: nil, compression: 2,
      ...>              sample_rate: 44100, frames_per_packet: 352}]
      iex> PiFi.AirPlay.Setup.streams_reply(streams, data: 6000, control: 6001)
      %{"streams" => [%{"type" => 96, "dataPort" => 6000, "controlPort" => 6001}]}
  """
  @spec streams_reply([stream()], keyword()) :: %{String.t() => term()}
  def streams_reply(streams, ports) do
    %{"streams" => Enum.map(streams, &reply_for(&1, ports))}
  end

  defp reply_for(%{kind: :buffered}, ports) do
    %{
      "type" => @buffered,
      "dataPort" => Keyword.fetch!(ports, :data),
      "controlPort" => Keyword.fetch!(ports, :control),
      "audioBufferSize" => Keyword.get(ports, :buffer_size, 8 * 1024 * 1024)
    }
  end

  defp reply_for(%{kind: :remote_control}, ports) do
    %{"type" => @remote_control, "dataPort" => Keyword.fetch!(ports, :data)}
  end

  defp reply_for(%{kind: :realtime}, ports) do
    %{
      "type" => @realtime,
      "dataPort" => Keyword.fetch!(ports, :data),
      "controlPort" => Keyword.fetch!(ports, :control)
    }
  end

  defp session(plist) do
    %{
      name: Map.get(plist, "name"),
      timing: timing(Map.get(plist, "timingProtocol")),
      remote_control_only?: Map.get(plist, "isRemoteControlOnly") == true
    }
  end

  # A sender that names no protocol is one that wants no timing, which is what a remote
  # control connection is.
  defp timing("PTP"), do: :ptp
  defp timing("NTP"), do: :ntp
  defp timing(_anything), do: :none

  defp streams([]), do: {:error, :no_streams}

  defp streams(streams) do
    Enum.reduce_while(streams, {:ok, []}, fn stream, {:ok, read} ->
      case stream(stream) do
        {:ok, one} -> {:cont, {:ok, read ++ [one]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, read} -> {:ok, {:streams, read}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream(%{"type" => type} = stream) do
    with {:ok, kind} <- kind(type),
         {:ok, key} <- key(Map.get(stream, "shk")) do
      {:ok,
       %{
         kind: kind,
         key: key,
         compression: Map.get(stream, "ct"),
         sample_rate: Map.get(stream, "sr"),
         frames_per_packet: Map.get(stream, "spf")
       }}
    end
  end

  defp stream(_stream), do: {:error, :stream_has_no_type}

  defp kind(@realtime), do: {:ok, :realtime}
  defp kind(@buffered), do: {:ok, :buffered}
  defp kind(@remote_control), do: {:ok, :remote_control}
  defp kind(type), do: {:error, {:unsupported_stream, type}}

  # A remote control stream carries no audio and so carries no key.
  defp key(nil), do: {:ok, nil}
  defp key({:data, key}) when byte_size(key) == @key_bytes, do: {:ok, key}
  defp key(key) when is_binary(key) and byte_size(key) == @key_bytes, do: {:ok, key}
  defp key({:data, key}), do: {:error, {:bad_session_key, byte_size(key)}}
  defp key(key) when is_binary(key), do: {:error, {:bad_session_key, byte_size(key)}}
  defp key(_key), do: {:error, :bad_session_key}
end
