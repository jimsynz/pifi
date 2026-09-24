defmodule PiFi.AirPlay.Session do
  @moduledoc """
  The audio half of one connection: the sockets a sender is told to use.

  `PiFi.AirPlay.Setup` reads what a sender asks for and says what to answer.
  `PiFi.AirPlay.AudioSocket` takes the audio. This is what joins them — it opens the
  ports, remembers them for the length of the connection, and closes them at the end.

  ## Three sockets, and only one of them carries audio

  A sender is given three port numbers across the two `SETUP` messages, and it connects
  to or sends to all of them. **A port named in an answer has to be listening**: a sender
  whose connection is refused gives up on the session, so naming a port nothing holds
  would fail the handshake as surely as answering `501`.

    * **event**, TCP. Carries what is playing, as plists, from this receiver to the
      sender. Opened and accepted; nothing is sent on it yet, because the metadata is
      useless until the audio works.
    * **data**, UDP. The audio. This is `PiFi.AirPlay.AudioSocket`.
    * **control**, UDP. Retransmit requests and timing from the sender. Opened so that
      what it sends has somewhere to go, and **not yet read**: asking for a lost packet
      again is worth doing and is not done here, so a stream on a poor network has the
      gaps it has.

  The two that are opened and not serviced are the honest cost of making the handshake
  complete. They degrade the audio on a bad network; they do not mislead a sender about
  what it is connected to.

  ## Sockets belong to the connection that made them

  Everything here is linked to the process that called `setup/2`, which is the
  connection. A telephone that goes away takes its TCP connection with it, the connection
  process ends, and the ports go with it — no session outlives the conversation that
  made it, and nothing has to notice a sender that vanished.
  """

  alias PiFi.AirPlay.AudioSocket
  alias PiFi.AirPlay.Setup

  @typedoc "What one connection has opened."
  @type t :: %__MODULE__{
          event: port() | nil,
          acceptor: pid() | nil,
          control: port() | nil,
          audio: pid() | nil,
          streams: [Setup.stream()],
          timing: :ptp | :ntp | :none | nil,
          name: String.t() | nil
        }

  defstruct event: nil,
            acceptor: nil,
            control: nil,
            audio: nil,
            streams: [],
            timing: nil,
            name: nil

  @doc "A session that has opened nothing."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Answer one `SETUP`, opening whatever it asks for.

  Gives back the plist to reply with and the session as it now stands.
  """
  @spec setup(t(), binary()) :: {:ok, map(), t()} | {:error, term()}
  def setup(%__MODULE__{} = session, body) do
    with {:ok, phase} <- Setup.read(body) do
      answer(session, phase)
    end
  end

  @doc """
  Take the next audio, if any has arrived.

  The same three answers `PiFi.AirPlay.AudioSocket.take/1` gives, and `:empty` for a
  session that has no audio stream at all.
  """
  @spec take(t()) :: {:ok, map()} | {:gap, pos_integer()} | :empty
  def take(%__MODULE__{audio: nil}), do: :empty
  def take(%__MODULE__{audio: audio}), do: AudioSocket.take(audio)

  @doc """
  Close everything this opened.

  A sender sends `TEARDOWN`, and a sender that crashed sends nothing at all — so this
  has to be safe to call on a session that opened none of it, and safe to call twice.
  """
  @spec close(t()) :: t()
  def close(%__MODULE__{} = session) do
    if session.audio && Process.alive?(session.audio), do: GenServer.stop(session.audio)
    # The acceptor owns whatever it accepted, so ending it is what closes that as well.
    # Closing the listener alone would leave a sender's event connection open until the
    # whole conversation ended.
    if session.acceptor, do: ended(session.acceptor)
    if session.event, do: :gen_tcp.close(session.event)
    if session.control, do: :gen_udp.close(session.control)

    %__MODULE__{}
  end

  defp answer(session, {:session, details}) do
    with {:ok, session} <- listening(session) do
      {:ok, port} = :inet.port(session.event)

      {:ok, Setup.session_reply(port), %{session | timing: details.timing, name: details.name}}
    end
  end

  defp answer(session, {:streams, streams}) do
    with {:ok, session} <- controlling(session),
         {:ok, session} <- hearing(session, streams) do
      {:ok, control} = :inet.port(session.control)
      {:ok, data} = data_port(session)

      {:ok, Setup.streams_reply(streams, data: data, control: control),
       %{session | streams: streams}}
    end
  end

  # A second `SETUP` on one connection reuses what is already open rather than opening
  # another of everything.
  defp listening(%{event: event} = session) when event != nil, do: {:ok, session}

  defp listening(session) do
    # A sender connects once and this receiver never dials out, so the backlog is one and
    # the accepting happens in a process of its own: an acceptor that blocked here would
    # stop the connection answering anything else.
    case :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, backlog: 1]) do
      {:ok, event} ->
        {:ok, %{session | event: event, acceptor: accepting(event)}}

      {:error, reason} ->
        {:error, {:no_event_port, reason}}
    end
  end

  defp controlling(%{control: control} = session) when control != nil, do: {:ok, session}

  defp controlling(session) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, control} -> {:ok, %{session | control: control}}
      {:error, reason} -> {:error, {:no_control_port, reason}}
    end
  end

  defp hearing(session, streams) do
    case Enum.find(streams, &(&1.kind in [:realtime, :buffered])) do
      nil -> {:ok, session}
      stream -> started(session, stream)
    end
  end

  defp started(%{audio: audio} = session, _stream) when audio != nil, do: {:ok, session}

  defp started(session, stream) do
    case AudioSocket.start_link(key: stream.key) do
      {:ok, audio} -> {:ok, %{session | audio: audio}}
      {:error, reason} -> {:error, {:no_audio_port, reason}}
    end
  end

  # A session of remote control alone has no audio socket, and the port it is given is
  # one that takes nothing. Naming the control port for both keeps the answer honest:
  # there is something listening on it either way.
  defp data_port(%{audio: nil, control: control}), do: :inet.port(control)
  defp data_port(%{audio: audio}), do: AudioSocket.port(audio)

  # Nothing is sent on the event channel yet, so this accepts the connection and holds
  # it open. A sender that finds nothing listening abandons the session; one whose
  # connection is accepted and then left quiet does not.
  #
  # **It happens in a process of its own and keeps the socket it accepted.** Accepting
  # here would block the connection from answering anything else, and holding the socket
  # somewhere with an owner is what lets `close/1` end it: a socket handed to the
  # connection process would outlive a `TEARDOWN`.
  defp accepting(listener) do
    spawn_link(fn ->
      case :gen_tcp.accept(listener) do
        {:ok, accepted} -> held(accepted)
        {:error, _closed} -> :ok
      end
    end)
  end

  # **Unlinked before it is ended**, because the acceptor is linked to the connection so
  # that it dies with it — and an exit signal down a live link would take the connection
  # with it instead, which is the opposite of closing one session tidily.
  defp ended(acceptor) do
    Process.unlink(acceptor)
    Process.exit(acceptor, :kill)
  end

  defp held(accepted) do
    :ok = :inet.setopts(accepted, active: true)

    receive do
      {:tcp_closed, ^accepted} -> :ok
      {:tcp_error, ^accepted, _reason} -> :ok
      # A sender says nothing on this channel, and anything it does say is not read yet.
      _anything -> held(accepted)
    end
  end
end
