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

  ## Everything after pairing is encrypted, and the reply that finishes it is not

  The message that completes a pairing is answered **in the clear**, and the message
  after that arrives as ciphertext. So the channel is made once that answer has gone out
  and never before it: a receiver that switched over one message early would send a
  telephone a reply it could not read, at the one moment it had no way to say so.

  After that there are two buffers rather than one — the ciphertext that has arrived and
  the plaintext it has yielded — because neither runs out in step with the other. A
  block can decrypt to half a request, and a request can finish in the middle of a
  block.

  ## A connection that will not parse is closed

  Not refused with a `400` and left open: a buffer that cannot be parsed will not parse
  any better with more bytes after it, and holding the socket open would leave a
  telephone waiting. A block whose tag does not check is the same — the stream is a
  sequence, and there is no finding the place again once one is lost.

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
  alias PiFi.AirPlay.SecureChannel

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    {:continue, %{buffer: <<>>, plain: <<>>, channel: nil, session: session_for(socket, state)}}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    with {:ok, plain, rest, state} <- decrypt(state.buffer <> data, state),
         {:ok, state} <- serve(state.plain <> plain, %{state | buffer: rest}, socket) do
      {:continue, state}
    else
      {:error, reason} ->
        Logger.warning("AirPlay connection closed: #{inspect(reason)}")

        {:close, state}
    end
  end

  # Before a pairing there is no channel and the bytes are already plain.
  defp decrypt(arrived, %{channel: nil} = state), do: {:ok, arrived, <<>>, state}

  defp decrypt(arrived, state) do
    case SecureChannel.open(state.channel, arrived) do
      {:ok, plain, rest, channel} -> {:ok, plain, rest, %{state | channel: channel}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp serve(plain, state, socket) do
    case Rtsp.parse(plain) do
      {:more, rest} ->
        {:ok, %{state | plain: rest}}

      {:ok, request, rest} ->
        {reply, session} = Router.route(request, state.session)

        state =
          %{state | session: session}
          |> answer(reply, socket)
          |> secure()

        serve(rest, state, socket)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp answer(%{channel: nil} = state, reply, socket) do
    ThousandIsland.Socket.send(socket, reply)

    state
  end

  defp answer(state, reply, socket) do
    {sealed, channel} = SecureChannel.seal(state.channel, reply)

    ThousandIsland.Socket.send(socket, sealed)

    %{state | channel: channel}
  end

  # **This runs after the answer has gone out**, which is what keeps the last message of
  # a pairing in the clear while the one after it is not.
  defp secure(%{channel: nil, session: %{keys: keys}} = state) when is_map(keys) do
    %{state | channel: SecureChannel.new(keys)}
  end

  defp secure(state), do: state

  defp session_for(socket, state) do
    sender =
      case ThousandIsland.Socket.peername(socket) do
        {:ok, {address, port}} -> "#{:inet.ntoa(address)}:#{port}"
        _other -> "unknown"
      end

    Router.new(state.device, sender, state.data_dir)
  end
end
