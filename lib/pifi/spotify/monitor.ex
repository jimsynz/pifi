defmodule PiFi.Spotify.Monitor do
  @moduledoc """
  Starts librespot again when what it was told stops being true.

  **librespot reads its name and its sound card once, as arguments.** Two of those
  move while a device runs, and neither one reaches a daemon that is already going:

  - A person renames the device, and `PiFi.Device.Identity` publishes
    `PiFi.Event.Device.IdentityChanged`. A Spotify device that kept the old name is
    one that a household with two of them cannot tell apart.
  - A person changes the DAC, or one arrives or goes, and `PiFi.Device.Monitor`
    publishes `PiFi.Event.Device.OutputChanged`. librespot would carry on writing to a
    card that is no longer there.

  This watches the `:device` topic for both and asks `PiFi.Spotify.restart/0`, which
  does nothing at all when the daemon is not running. **A short silence is better than
  a wrong name or a dead card**, and neither event happens while a person is listening
  to anything: renaming the device and changing the DAC are both done from the settings
  page.

  ## It listens on three topics, and `:player` is the one that carries a cast

  `PiFi.Event.Spotify.SinkChanged` rides the `:player` topic, because a cast taking the
  sound path is a fact about what is playing. **This process subscribed to `:device` and
  `:source` alone, so every sink event went past it** and a cast reached librespot and
  stopped there: the loopback filled with audio and nothing read it.

  The cost of the third subscription is a `PiFi.Event.Player.Progress` once a second
  while anything plays, which is one message and one match that does not fit.

  ## It also starts and stops the daemon

  A person turns Spotify on with the source switch, and that switch is the generic one:
  `PiFi.Playback.enable_source/2` writes a setting and knows nothing about any source.
  A special case there for the one source with a daemon is what `PiFi.Source` exists to
  prevent, so the setting says what happened on the `:source` topic and this acts on
  it. See `PiFi.Event.Source.EnabledChanged`.

  ## It runs whether the daemon does or not

  This is a child of `PiFi.Spotify` from the start, unlike the daemon beside it.
  Watching two topics costs nothing, and a monitor that only existed while the daemon
  did would have to be started and stopped by the same code that starts and stops the
  daemon, for no gain.
  """

  use GenServer

  require Logger

  alias PiFi.Event
  alias PiFi.Event.Device.IdentityChanged
  alias PiFi.Event.Device.OutputChanged
  alias PiFi.Event.Source.EnabledChanged
  alias PiFi.Event.Spotify.SinkChanged
  alias PiFi.Event.Spotify.TrackChanged

  @doc false
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc false
  @impl GenServer
  def init(_options) do
    :ok = Event.subscribe(:device)
    :ok = Event.subscribe(:player)
    :ok = Event.subscribe(:source)

    {:ok, nil}
  end

  @doc false
  @impl GenServer
  def handle_info(%IdentityChanged{}, state) do
    PiFi.Spotify.restart()

    {:noreply, state}
  end

  def handle_info(%OutputChanged{}, state) do
    PiFi.Spotify.restart()

    {:noreply, state}
  end

  def handle_info(%EnabledChanged{source: PiFi.Source.Spotify}, state) do
    PiFi.Spotify.follow_setting()

    {:noreply, state}
  end

  # **librespot opening its sink is the only thing that says a cast began.** The capture
  # side of the loopback hands over full-rate silence whether anything plays or not, so
  # a pipeline started on data would never stop. See `PiFi.Spotify.Loopback`.
  def handle_info(%SinkChanged{state: :running}, state) do
    case PiFi.Player.play(PiFi.Source.Spotify.item()) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("A cast did not reach the player: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # **A pause is not a stop, and the difference is the sound card.** librespot calls it
  # `temporarily_closed` and opens the sink again without a new track, so the player
  # pauses and keeps the stream rather than tearing the pipeline down and paying a
  # second of silence to build it again.
  def handle_info(%SinkChanged{state: :paused}, state) do
    PiFi.Player.pause(true)

    {:noreply, state}
  end

  # **Only a cast that this device is playing may stop it.** A `closed` that arrived
  # while a person was listening to something else would take their music away, and
  # librespot sends one whenever it lets go of its sink.
  def handle_info(%SinkChanged{state: :closed}, state) do
    if casting?(), do: PiFi.Player.stop()

    {:noreply, state}
  end

  # The title and the artist of a cast ride where the ICY title of a station rides. See
  # `PiFi.Source.Spotify.item/0`.
  def handle_info(%TrackChanged{track: track}, state) do
    if casting?(), do: PiFi.Player.metadata(now_playing(track))

    {:noreply, state}
  end

  # The storage and the battery report on the `:device` topic as well, every other
  # source reports on the `:source` one, and none of that is an argument that librespot
  # was given.
  def handle_info(_message, state), do: {:noreply, state}

  defp casting? do
    match?(%{source: PiFi.Source.Spotify}, PiFi.Playback.state!())
  end

  # **One line, because that is what a station gives.** A screen and a page both draw
  # the ICY title of a station as one line, and a cast has a title and an artist that
  # read the same way.
  defp now_playing(%{title: title, artists: artists}) when is_binary(artists) and artists != "" do
    title <> " · " <> artists
  end

  defp now_playing(%{title: title}), do: title
end
