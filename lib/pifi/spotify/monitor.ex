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

  ## It runs whether the daemon does or not

  This is a child of `PiFi.Spotify` from the start, unlike the daemon beside it.
  Watching two topics costs nothing, and a monitor that only existed while the daemon
  did would have to be started and stopped by the same code that starts and stops the
  daemon, for no gain.
  """

  use GenServer

  alias PiFi.Event
  alias PiFi.Event.Device.IdentityChanged
  alias PiFi.Event.Device.OutputChanged

  @doc false
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc false
  @impl GenServer
  def init(_options) do
    :ok = Event.subscribe(:device)

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

  # The storage and the battery report on this topic as well, and neither one is an
  # argument that librespot was given.
  def handle_info(_message, state), do: {:noreply, state}
end
