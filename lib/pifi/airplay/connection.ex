defmodule PiFi.AirPlay.Connection do
  @moduledoc """
  One telephone talking to this device.

  A process for each connection, holding the bytes that have arrived and the pairing
  that is part way through. `PiFi.AirPlay.Router` decides what each request means; this
  reads the socket, hands whole requests over, and writes the answers back.

  ## A request arrives in pieces, and more than one arrives at once

  TCP gives no message boundaries. A `POST /pair-setup` carrying four hundred bytes of
  SRP arrives in two segments as often as one, and two small requests arrive together.
  So every read appends to a buffer and **the buffer is drained until it stops yielding
  whole requests**, rather than being parsed once per read. A handler that assumed one
  read was one request would work on a desk and stall on a board.

  ## A connection that will not parse is closed

  Not refused with a `400` and left open: a buffer that cannot be parsed will not parse
  any better with more bytes after it, and holding the socket open would leave a
  telephone waiting. There is no recovering the frame once it is lost.

  ## The device facts are read once

  Its name, its keys and its identifiers are settled when the connection opens and do
  not change under it. A person who renames the device mid-connection gets the old name
  until the telephone reconnects, which is what a sender expects anyway — the name is in
  the mDNS record it already read.
  """

  use ThousandIsland.Handler

  require Logger

  alias PiFi.AirPlay.Router
  alias PiFi.AirPlay.Rtsp

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    {:ok, session} = session_for(socket, state)

    {:continue, %{buffer: <<>>, session: session}}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    case drain(state.buffer <> data, state.session, socket) do
      {:ok, buffer, session} -> {:continue, %{state | buffer: buffer, session: session}}
      {:error, reason} -> {:close, log_and_keep(state, reason)}
    end
  end

  defp drain(buffer, session, socket) do
    case Rtsp.parse(buffer) do
      {:more, rest} ->
        {:ok, rest, session}

      {:ok, request, rest} ->
        {reply, session} = Router.route(request, session)

        ThousandIsland.Socket.send(socket, reply)

        drain(rest, session, socket)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp log_and_keep(state, reason) do
    Logger.warning("AirPlay connection closed: #{inspect(reason)}")

    state
  end

  defp session_for(socket, state) do
    sender =
      case ThousandIsland.Socket.peername(socket) do
        {:ok, {address, port}} -> "#{:inet.ntoa(address)}:#{port}"
        _other -> "unknown"
      end

    {:ok, Router.new(state.device, sender, state.data_dir)}
  end
end
