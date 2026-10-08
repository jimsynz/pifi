defmodule PiFi.AirPlay.BufferedSocket do
  @moduledoc """
  Listens for the audio of a buffered AirPlay session, and holds it until it is asked
  for.

  `PiFi.AirPlay.AudioSocket` is the same job for a realtime session, and the two have
  the same shape on purpose: `port/1` says what to name in the answer to `SETUP`,
  `take/1` hands on the next frame, and `statistics/1` says what arrived. The rest of
  the firmware therefore holds one path for both.

  ## Two kinds of session, and this is the one a telephone picks

  A sender reads the feature bits of `PiFi.AirPlay.Advertisement`, and bit 40 says that
  this receiver takes buffered audio. A telephone that sees it sends stream type 103
  rather than type 96, and **none of the realtime path then applies**: the audio comes
  over TCP rather than UDP, it is AAC rather than ALAC, and the sender runs ahead of
  the sound rather than in step with it.

  A board at 192.168.3.142 showed what happens when only half of that is true. The
  receiver claimed the feature, opened a UDP socket, and named that port as the
  `dataPort` of a buffered stream. The telephone tried to open a TCP connection to a
  number nothing was listening on, asked about forty times for the audio to start, and
  then gave up.

  ## It is the realtime packet in a length

  The block on the wire is `<<length::16, packet::binary>>`, and **the length counts
  its own two bytes**. What is inside is an ordinary RTP packet sealed exactly as a
  realtime one is, so `PiFi.AirPlay.AudioPacket` reads it without a word of its own.
  Shairport Sync makes this look like a private framing because it works in offsets
  from the length; the moduledoc of that module says why it is not.

  ## No jitter buffer, because TCP has none of that problem

  A realtime session arrives on UDP, so `PiFi.AirPlay.JitterBuffer` puts the packets in
  order and reports what never came. TCP delivers in order or not at all, so the frames
  go in a queue and nothing here conceals a gap. A sender that stops sending is a
  sender that stopped, and the socket closing says so.

  ## The sender is paced by the reading, and by nothing else

  `audioBufferSize` tells a sender how far ahead it may run, and it will fill that much
  as fast as the network allows. Nothing here asks it to slow down: the socket is read
  only when the audio is asked for, so the window closes, and the sender waits on it.
  That is the same arrangement `PiFi.Player.HttpSource` has with a radio station, and
  it is why the sound card stays the only clock.

  ## A frame leaves with an ADTS header on it

  The frames arrive bare, and `Membrane.AAC.FDK.Decoder` reads the ADTS transport layer
  rather than naked AAC. `PiFi.Player.AdtsFrame.header/3` builds one for each frame
  from the rate and the channel count that `SETUP` named.
  """

  use GenServer

  alias PiFi.AirPlay.AudioPacket
  alias PiFi.Player.AdtsFrame

  require Logger

  # How many messages the socket delivers before it waits to be asked again. The same
  # reason as `PiFi.AirPlay.AudioSocket`: a sender that fills the mailbox faster than
  # this process drains it takes the memory of the board with it.
  @in_flight 16

  @typedoc "What one socket has seen."
  @type statistics :: %{
          received: non_neg_integer(),
          refused: non_neg_integer(),
          held: non_neg_integer()
        }

  @typedoc "One frame of AAC, with an ADTS header in front of it."
  @type frame :: %{payload: binary()}

  @doc """
  Open a socket for one buffered session.

  `:key` is the thirty-two bytes the sender gave as `shk`. `:sample_rate` and
  `:channels` come from the same `SETUP` and go into the ADTS header of each frame.
  `:port` asks for a particular one and defaults to letting the operating system
  choose.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @doc "The port this bound, which is what the answer to `SETUP` names."
  @spec port(GenServer.server()) :: {:ok, :inet.port_number()} | {:error, term()}
  def port(socket), do: GenServer.call(socket, :port)

  @doc """
  Take the next frame, if there is one to take.

  - `{:ok, frame}` — the next frame, with its ADTS header.
  - `:empty` — nothing yet. Ask again.
  """
  @spec take(GenServer.server()) :: {:ok, frame()} | :empty
  def take(socket), do: GenServer.call(socket, :take)

  @doc "How many frames arrived, how many would not open, and how many are waiting."
  @spec statistics(GenServer.server()) :: statistics()
  def statistics(socket), do: GenServer.call(socket, :statistics)

  @doc false
  @impl GenServer
  def init(options) do
    listen = [:binary, active: false, reuseaddr: true, backlog: 1, packet: :raw]

    sample_rate = Keyword.get(options, :sample_rate) || 44_100
    channels = Keyword.get(options, :channels) || 2

    # **The rate is checked here and not on each frame.** A rate that ADTS cannot name
    # gives no header, and a check inside the reading would refuse every frame of the
    # session without a word about why.
    with header when is_binary(header) <- AdtsFrame.header(sample_rate, channels, 0),
         {:ok, listener} <- :gen_tcp.listen(Keyword.get(options, :port, 0), listen) do
      {:ok,
       %{
         listener: listener,
         socket: nil,
         acceptor: accepting(listener),
         key: Keyword.fetch!(options, :key),
         sample_rate: sample_rate,
         channels: channels,
         buffer: <<>>,
         frames: :queue.new(),
         held: 0,
         received: 0,
         refused: 0
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @doc false
  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, :inet.port(state.listener), state}

  def handle_call(:take, _from, state) do
    case :queue.out(state.frames) do
      {{:value, frame}, frames} ->
        {:reply, {:ok, frame}, %{state | frames: frames, held: state.held - 1}}

      {:empty, _frames} ->
        {:reply, :empty, state}
    end
  end

  def handle_call(:statistics, _from, state) do
    {:reply, %{received: state.received, refused: state.refused, held: state.held}, state}
  end

  @doc false
  @impl GenServer
  def handle_info({:accepted, socket}, %{socket: nil} = state) do
    :ok = :inet.setopts(socket, active: @in_flight)

    Logger.info("A telephone opened the buffered AirPlay connection.")

    {:noreply, %{state | socket: socket}}
  end

  # One sender at a time. A second connection is refused rather than taken, because the
  # audio of two telephones through one decoder is noise.
  def handle_info({:accepted, socket}, state) do
    :gen_tcp.close(socket)

    {:noreply, state}
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    case read(%{state | buffer: state.buffer <> data}) do
      {:ok, state} ->
        {:noreply, state}

      # **A block this receiver cannot read is the end of the stream.** The next block
      # begins wherever the unreadable one was supposed to end, and there is no finding
      # that place again.
      {:error, reason, state} ->
        Logger.warning("The buffered AirPlay stream lost its place: #{inspect(reason)}")

        {:stop, :normal, state}
    end
  end

  # The socket delivered its allowance and stopped. Asking for the next lot here rather
  # than on a timer is what keeps a sender from outrunning this process.
  def handle_info({:tcp_passive, socket}, %{socket: socket} = state) do
    :ok = :inet.setopts(socket, active: @in_flight)

    {:noreply, state}
  end

  # **The audio ending is the session ending.** `PiFi.AirPlay.Monitor` watches this
  # process, so stopping is what tells the player that the music is over.
  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.info("The buffered AirPlay connection closed.")

    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.warning("The buffered AirPlay connection failed: #{inspect(reason)}")

    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @impl GenServer
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    :gen_tcp.close(state.listener)
  end

  # **A block names its own length, and that length counts the two bytes of itself.**
  # Anything shorter than the whole block stays in the buffer until the rest arrives:
  # TCP gives no message boundaries, so a read is as likely to hold half a block as a
  # whole one.
  defp read(%{buffer: <<length::16, _rest::binary>>} = state) when length <= 2 do
    {:error, {:block_of_nothing, length}, state}
  end

  defp read(%{buffer: <<length::16, rest::binary>>} = state)
       when byte_size(rest) >= length - 2 do
    body = binary_part(rest, 0, length - 2)
    tail = binary_part(rest, length - 2, byte_size(rest) - (length - 2))

    %{state | buffer: tail}
    |> took(body)
    |> read()
  end

  defp read(state), do: {:ok, state}

  defp took(state, body) do
    state = %{state | received: state.received + 1}

    case AudioPacket.open(body, state.key) do
      {:ok, packet} ->
        header = AdtsFrame.header(state.sample_rate, state.channels, byte_size(packet.payload))

        %{
          state
          | frames: :queue.in(%{payload: header <> packet.payload}, state.frames),
            held: state.held + 1
        }

      # A frame that will not open is one frame of audio, and the stream carries on.
      # **None of these is logged**: a stream going wrong would write a line per frame,
      # forty a second, and `statistics/1` carries the count instead.
      {:error, _reason} ->
        %{state | refused: state.refused + 1}
    end
  end

  # **Accepting happens in a process of its own**, because `:gen_tcp.accept/1` blocks
  # and this one has audio to hand out. It gives the socket to this process and says so,
  # which is what `handle_info({:accepted, _}, _)` above takes.
  defp accepting(listener) do
    owner = self()

    spawn_link(fn -> accept(listener, owner) end)
  end

  defp accept(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :ok = :gen_tcp.controlling_process(socket, owner)
        send(owner, {:accepted, socket})

        accept(listener, owner)

      {:error, _closed} ->
        :ok
    end
  end
end
