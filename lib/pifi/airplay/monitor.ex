defmodule PiFi.AirPlay.Monitor do
  @moduledoc """
  Turns a sender starting and stopping into the player playing and stopping.

  Two jobs, and they are the same job from different ends. It follows the switch, so
  turning the source on opens the port and turning it off shuts it; and it follows the
  sessions, so a telephone that starts sending makes this device play what it sends.

  `PiFi.Spotify.Monitor` does the same for librespot, and the shape is deliberately the
  same: a push input is a telephone deciding what plays, and the player should not have
  to know which protocol carried it.

  ## The switch leads and the listener follows, but not silently

  A source is enabled by writing a setting, so the setting is what a person changed and
  the port has to catch up. **A port another program holds would otherwise leave a
  person looking at a switch that says on, with nothing listening.** So a listener that
  will not start puts the switch back and says why, which keeps the two from disagreeing
  in the one direction that matters.

  ## Which session is current, and why nothing carries it

  `PiFi.Source.AirPlay.resolve/1` has no socket to give: a session lasts as long as one
  telephone stays connected, and `PiFi.Player` builds its pipeline again whenever the
  output changes. A pid put into a playable would be dead by the time the second
  pipeline used it. So the playable says `:airplay` and the pipeline asks `socket/0`
  at the moment it builds.

  ## Only a stream this device is playing may stop it

  A `TEARDOWN` from a telephone that was never the one playing must not take a person's
  music away — the same care `PiFi.Spotify.Monitor` takes about librespot closing its
  sink while somebody is listening to the radio.
  """

  use GenServer

  alias PiFi.AirPlay.Server
  alias PiFi.Event.Source.EnabledChanged
  alias PiFi.Source.AirPlay

  require Logger

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc """
  Note that a sender began a stream, and start playing it.

  The socket is the one `PiFi.AirPlay.Session` opened for that sender.
  """
  @spec started(pid()) :: :ok
  def started(socket), do: GenServer.cast(__MODULE__, {:started, socket})

  @doc "Note that the stream ended, and stop playing it."
  @spec stopped(pid()) :: :ok
  def stopped(socket), do: GenServer.cast(__MODULE__, {:stopped, socket})

  @doc "The socket of the session that is streaming now, if one is."
  @spec socket() :: pid() | nil
  def socket, do: GenServer.call(__MODULE__, :socket)

  @doc false
  @impl GenServer
  def init(_options) do
    PiFi.Event.subscribe(:source)

    {:ok, %{socket: nil}}
  end

  @doc false
  @impl GenServer
  def handle_call(:socket, _from, state), do: {:reply, state.socket, state}

  @doc false
  @impl GenServer
  def handle_cast({:started, socket}, state) do
    case PiFi.Player.play(AirPlay.item()) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("An AirPlay stream did not play: #{inspect(reason)}")
    end

    {:noreply, %{state | socket: socket}}
  end

  # A sender that was not the one playing has nothing to stop.
  def handle_cast({:stopped, socket}, %{socket: socket} = state) do
    if playing?(), do: PiFi.Player.stop()

    {:noreply, %{state | socket: nil}}
  end

  def handle_cast({:stopped, _other}, state), do: {:noreply, state}

  @doc false
  @impl GenServer
  def handle_info(%EnabledChanged{source: AirPlay, enabled?: true}, state) do
    case Server.enable(true) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("AirPlay did not start: #{inspect(reason)}")

        PiFi.Source.enable(AirPlay, false)
    end

    {:noreply, state}
  end

  def handle_info(%EnabledChanged{source: AirPlay, enabled?: false}, state) do
    Server.enable(false)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp playing? do
    match?(%{source: AirPlay}, PiFi.Playback.state!())
  end
end
