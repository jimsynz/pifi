defmodule PiFi.AirPlay.ControlSocket do
  @moduledoc """
  The control channel of one session: it asks for the packets that did not arrive.

  `PiFi.AirPlay.AudioSocket` takes the audio and `PiFi.AirPlay.JitterBuffer` decides
  when a packet that has not come is not coming. This is what gets a second chance at
  one. Until it existed the port was opened so that what a sender sent had somewhere to
  go, and nothing read it, so a stream on a poor network kept the gaps it got.

  ## Three payload types, and this reads one of them

  The control channel carries RTP packets of its own, and AirPlay gives them payload
  types above the audio:

  | Type | Direction | What it is |
  | ---- | --------- | ---------- |
  | `0x54` | sender → here | a timing packet, which `PiFi.AirPlay.Rtp` does not need |
  | `0x55` | here → sender | **ask for these packets again** |
  | `0x56` | sender → here | **here they are**, with the original packet inside |

  A `0x54` is read for one thing only: the address and port it came from. See below.

  ## It learns where to send rather than being told

  A sender names its own control port in the `SETUP` plist, and this does not read it.
  **The first packet to arrive says the same thing and cannot be stale**: a sender that
  moved, or one whose plist this firmware read wrongly, still gets the request at the
  place it is actually sending from. Nothing is asked for until something has arrived,
  which is also the only moment at which there is anything to ask about.

  ## A request is a hint and never a promise

  Everything here fails quietly. A sender may ignore the request, answer it late enough
  that the buffer has given up, or not implement it at all — and in each case the audio
  is what it would have been without this. So a send that fails is counted and not
  logged: these arrive hundreds a second on a bad network, which is the trap the ALAC
  decoder had to be saved from. `statistics/1` is how a board says whether it is
  working.

  ## The shapes come from Shairport Sync

  `rtp.c` of that project is MIT, and it is where the four-byte prefix on a `0x56` and
  the eight-byte shape of a `0x55` are written down. They have not been checked against
  a real telephone here, which is why nothing depends on them: a wrong reading loses the
  retransmits and takes nothing else with it.
  """

  use GenServer

  alias PiFi.AirPlay.AudioSocket

  @version 2

  @request 0x55
  @reply 0x56

  # A reply carries the original packet after its own header, which is the twelve bytes
  # of an RTP header with four of them spent and the rest unused.
  @reply_prefix 4

  # How many datagrams the socket delivers before it waits to be asked again, in the way
  # that `PiFi.AirPlay.AudioSocket` reads in bursts.
  @in_flight 64

  @typedoc "What this channel has done."
  @type statistics :: %{
          asked: non_neg_integer(),
          answered: non_neg_integer(),
          ignored: non_neg_integer()
        }

  @doc """
  Open the control socket for one session.

  `:audio` is the `PiFi.AirPlay.AudioSocket` that a retransmitted packet goes to. It is
  optional because the control port is answered for a session of remote control alone,
  which carries no audio at all.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @doc "The port this bound, which is what the answer to `SETUP` names."
  @spec port(GenServer.server()) :: {:ok, :inet.port_number()} | {:error, term()}
  def port(socket), do: GenServer.call(socket, :port)

  @doc """
  Name the audio socket that retransmitted packets go to.

  The control port is opened before the audio port, because the answer to `SETUP` names
  both and a session of remote control alone has only the first.
  """
  @spec audio(GenServer.server(), pid()) :: :ok
  def audio(socket, audio), do: GenServer.cast(socket, {:audio, audio})

  @doc """
  Ask the sender for `count` packets starting at `first`.

  It does nothing at all until a packet has arrived, because nothing knows where to
  send until then.
  """
  @spec request(GenServer.server(), 0..65_535, pos_integer()) :: :ok
  def request(socket, first, count), do: GenServer.cast(socket, {:request, first, count})

  @doc "How many packets were asked for, how many came back, and how much was ignored."
  @spec statistics(GenServer.server()) :: statistics()
  def statistics(socket), do: GenServer.call(socket, :statistics)

  @doc """
  The eight bytes that ask for a run of packets.

  It is public so a test reads the shape without a socket.

      iex> PiFi.AirPlay.ControlSocket.ask(7, 3)
      <<0x80, 0xD5, 0x00, 0x01, 0::8, 7::8, 0::8, 3::8>>
  """
  @spec ask(0..65_535, pos_integer()) :: binary()
  def ask(first, count) do
    # The marker bit is set on every control packet of this kind, and the sequence of
    # the request itself is 1 and never read.
    <<@version::2, 0::1, 0::1, 0::4, 1::1, @request::7, 1::16, first::16, count::16>>
  end

  @doc """
  The original datagram inside a retransmit reply, or `:error`.

      iex> PiFi.AirPlay.ControlSocket.inner(<<0x80, 0xD6, 0::16, "the original packet">>)
      {:ok, "the original packet"}

      iex> PiFi.AirPlay.ControlSocket.inner(<<0x80, 0xD4, 0::16, "a timing packet">>)
      :error
  """
  @spec inner(binary()) :: {:ok, binary()} | :error
  def inner(
        <<@version::2, _padding::1, _extension::1, _csrcs::4, _marker::1, @reply::7,
          _rest::binary>> = datagram
      )
      when byte_size(datagram) > @reply_prefix do
    <<_prefix::binary-size(@reply_prefix), inner::binary>> = datagram

    {:ok, inner}
  end

  def inner(_datagram), do: :error

  @doc false
  @impl GenServer
  def init(options) do
    open = [:binary, active: @in_flight]

    case :gen_udp.open(Keyword.get(options, :port, 0), open) do
      {:ok, socket} ->
        {:ok,
         %{
           socket: socket,
           audio: Keyword.get(options, :audio),
           peer: nil,
           asked: 0,
           answered: 0,
           ignored: 0
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @doc false
  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, :inet.port(state.socket), state}

  def handle_call(:statistics, _from, state) do
    {:reply, Map.take(state, [:asked, :answered, :ignored]), state}
  end

  @doc false
  @impl GenServer
  def handle_cast({:audio, audio}, state), do: {:noreply, %{state | audio: audio}}

  def handle_cast({:request, _first, _count}, %{peer: nil} = state), do: {:noreply, state}

  def handle_cast({:request, first, count}, %{peer: {address, port}} = state) do
    case :gen_udp.send(state.socket, address, port, ask(first, count)) do
      :ok -> {:noreply, %{state | asked: state.asked + count}}
      {:error, _reason} -> {:noreply, %{state | ignored: state.ignored + 1}}
    end
  end

  @doc false
  @impl GenServer
  def handle_info({:udp, socket, address, port, datagram}, %{socket: socket} = state) do
    {:noreply, %{state | peer: {address, port}} |> took(datagram)}
  end

  def handle_info({:udp_passive, socket}, %{socket: socket} = state) do
    :ok = :inet.setopts(socket, active: @in_flight)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @impl GenServer
  def terminate(_reason, %{socket: socket}), do: :gen_udp.close(socket)

  # A timing packet says where the sender is and nothing else this firmware reads, so it
  # is counted rather than parsed. See the module documentation.
  defp took(%{audio: nil} = state, _datagram), do: %{state | ignored: state.ignored + 1}

  defp took(state, datagram) do
    case inner(datagram) do
      {:ok, inner} ->
        AudioSocket.deliver(state.audio, inner)

        %{state | answered: state.answered + 1}

      :error ->
        %{state | ignored: state.ignored + 1}
    end
  end
end
