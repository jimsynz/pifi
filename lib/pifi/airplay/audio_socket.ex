defmodule PiFi.AirPlay.AudioSocket do
  @moduledoc """
  Listens for the audio of one AirPlay session, and holds it until it is asked for.

  This is the first part of the receiver that opens a socket. It binds a UDP port, takes
  the encryption off each datagram with `PiFi.AirPlay.AudioPacket`, and puts what comes
  out into a `PiFi.AirPlay.JitterBuffer`. `take/1` reads it back in order.

  ## Whoever has the clock does the taking

  **Nothing is pushed.** The first version of this drained the buffer after every
  datagram and sent what came out, which reordered nothing at all: reading starts at the
  oldest packet held, so a packet that arrived first was handed on first and the two that
  overtook it were then too late to use. A jitter buffer only works if packets are
  allowed to sit in it.

  So the rate belongs to whatever is playing the audio — a sound card consumes a frame
  every few milliseconds and that is the clock. This module has no clock and does not
  want one.

  ## The port is chosen by the operating system

  A sender is told where to send in the answer to `SETUP`, so the number does not have to
  be one this firmware picked — and a fixed port would refuse a second session while the
  first was still closing. `port/1` reads back what was bound, which is what goes in that
  answer.

  ## A datagram that will not open is dropped and counted

  These arrive from anything on the network, so one can be anything at all: a stray
  packet, one damaged on the way, or one from a session that has gone. None of them is a
  reason to end a session, and **none is logged** — a bad stream would otherwise write a
  line per packet, hundreds a second, which is the trap the ALAC decoder already had to
  be saved from. `statistics/1` carries the counts instead, which is the only way to see
  a stream going wrong on a board nobody can attach a debugger to.

  ## It reads in bursts and then asks for more

  The socket delivers a fixed number of datagrams and goes quiet until it is asked again.
  Without that a sender fills the mailbox of this process faster than it drains, and the
  memory of a board that has 363 MB goes with it.
  """

  use GenServer

  alias PiFi.AirPlay.AudioPacket
  alias PiFi.AirPlay.JitterBuffer

  # How many datagrams the socket delivers before it waits to be asked again.
  @in_flight 64

  # **The kernel holds what arrives while this process is busy.** A stream is about 350
  # packets a second, and a pause for garbage collection at the wrong moment drops
  # whatever does not fit. This is about a second of audio.
  @receive_buffer 1024 * 1024

  @typedoc "What one socket has seen."
  @type statistics :: %{
          received: non_neg_integer(),
          refused: non_neg_integer(),
          held: non_neg_integer()
        }

  @doc """
  Open a socket for one session.

  `:key` is the thirty-two bytes the sender gave as `shk`. `:port` asks for a particular
  one and defaults to letting the operating system choose; `:depth` and `:capacity` go to
  the buffer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @doc "The port this bound, which is what the answer to `SETUP` names."
  @spec port(GenServer.server()) :: {:ok, :inet.port_number()} | {:error, term()}
  def port(socket), do: GenServer.call(socket, :port)

  @doc """
  Take the next audio, if there is any to take.

  - `{:ok, packet}` — the frame that was due.
  - `{:gap, count}` — that many packets are not coming. Something above conceals them,
    because whether a gap sounds like silence or like the last frame again is a decision
    about sound rather than about ordering.
  - `:empty` — nothing yet. Ask again.
  """
  @spec take(GenServer.server()) :: {:ok, AudioPacket.t()} | {:gap, pos_integer()} | :empty
  def take(socket), do: GenServer.call(socket, :take)

  @doc "How many datagrams arrived, how many would not open, and how many are waiting."
  @spec statistics(GenServer.server()) :: statistics()
  def statistics(socket), do: GenServer.call(socket, :statistics)

  @doc false
  @impl GenServer
  def init(options) do
    key = Keyword.fetch!(options, :key)

    open = [:binary, active: @in_flight, recbuf: @receive_buffer]

    case :gen_udp.open(Keyword.get(options, :port, 0), open) do
      {:ok, socket} ->
        {:ok,
         %{
           socket: socket,
           key: key,
           buffer: JitterBuffer.new(Keyword.take(options, [:depth, :capacity])),
           received: 0,
           refused: 0
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @doc false
  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, :inet.port(state.socket), state}

  def handle_call(:take, _from, state) do
    case JitterBuffer.pop(state.buffer) do
      {:empty, buffer} -> {:reply, :empty, %{state | buffer: buffer}}
      {:ok, packet, buffer} -> {:reply, {:ok, packet}, %{state | buffer: buffer}}
      {:gap, count, buffer} -> {:reply, {:gap, count}, %{state | buffer: buffer}}
    end
  end

  def handle_call(:statistics, _from, state) do
    {:reply,
     %{
       received: state.received,
       refused: state.refused,
       held: JitterBuffer.count(state.buffer)
     }, state}
  end

  @doc false
  @impl GenServer
  def handle_info({:udp, socket, _address, _port, datagram}, %{socket: socket} = state) do
    {:noreply, took(state, datagram)}
  end

  # The socket delivered its allowance and stopped. Asking for the next lot here rather
  # than on a timer is what keeps a sender from outrunning this process.
  def handle_info({:udp_passive, socket}, %{socket: socket} = state) do
    :ok = :inet.setopts(socket, active: @in_flight)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @impl GenServer
  def terminate(_reason, %{socket: socket}), do: :gen_udp.close(socket)

  defp took(state, datagram) do
    state = %{state | received: state.received + 1}

    case AudioPacket.open(datagram, state.key) do
      {:ok, packet} ->
        %{state | buffer: JitterBuffer.push(state.buffer, packet.sequence, packet)}

      {:error, _reason} ->
        %{state | refused: state.refused + 1}
    end
  end
end
