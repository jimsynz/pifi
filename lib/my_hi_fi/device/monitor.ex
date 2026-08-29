# `vintage_net` and `nerves_uevent` are target dependencies, so the host build must
# hold no reference to this module. See `MyHiFi.Setup.Monitor` for the same pattern.
if Mix.target() != :host do
  defmodule MyHiFi.Device.Monitor do
    @moduledoc """
    Publishes the state of the hardware when it changes.

    Three reports of the settings page change without a person: a DAC arrives, Wi-Fi
    connects, and a download fills the card. The page read all three on a five second
    interval before, and each read gave the same answer almost every time. This process
    owns the three sources of truth instead, and it publishes a struct of
    `MyHiFi.Event.Device` on the `:device` topic when an answer changes.

    Each source of truth is a different shape, and each one cost a measurement to find.

    - **VintageNet holds the network, and it sends the old tuple.** Its property table
      is made with `tuple_events: true`, so a subscriber gets
      `{VintageNet, property, old, new, metadata}` and not a `PropertyTable.Event`.
    - **NervesUEvent holds the sound cards, and it sends the struct.** It arrives with
      `nerves_runtime`, so this needs no new dependency. The property of a device is its
      path in `/sys`, and that path is different on each board, so this subscribes to
      every uevent and reads the subsystem of each one. A removal carries the map in
      `previous_value` and nothing in `value`.
    - **The cache is the only part that writes a file that stays**, so a write there is
      the one thing that moves the free space of the card. `MyHiFi.Cache.Entry` names
      `Ash.Notifier.PubSub`, and this process is the one subscriber of it. A download of
      an episode grows outside the cache and `MyHiFi.Cache.put_file/3` moves it in when
      it is whole, so the free space settles at the moment of that notification.
      `MyHiFi.Device.Storage.Report` reads `df` and not `:disksup`, because `:disksup`
      holds a measurement of up to 30 minutes ago and a report after a write must be
      fresh.

    A sync of the station artwork writes many files in a moment, and each one is a
    notification. One read for each of them would run `df` hundreds of times, so a
    notification asks for one read a moment later and the ones behind it join that read.
    """

    use GenServer

    alias MyHiFi.Device
    alias MyHiFi.Event
    alias MyHiFi.Event.Device, as: Events
    alias MyHiFi.Playback

    @cache_topic "cache_entry:written"

    # How long a notification of the cache waits for the ones behind it.
    @settle :timer.seconds(2)

    @doc false
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

    @impl GenServer
    def init(_options) do
      # The subscription comes before the first read, or a change between the two is
      # lost. See `PropertyTable.subscribe/2`.
      :ok = VintageNet.subscribe(["interface"])
      :ok = NervesUEvent.subscribe([])
      :ok = Phoenix.PubSub.subscribe(MyHiFi.PubSub, @cache_topic)

      {:ok, %{network: nil, output: nil, storage: nil, settling?: false},
       {:continue, :first_read}}
    end

    # The state that the device holds at the start is not a change, so this reads it and
    # publishes nothing. It runs after `init/1` gives the process to the supervisor,
    # because a read of the output asks the player and the player answers a call.
    @impl GenServer
    def handle_continue(:first_read, state) do
      {:noreply, %{state | network: network(), output: output(), storage: storage()}}
    end

    @impl GenServer
    def handle_info({VintageNet, _property, _old, _new, _metadata}, state) do
      {:noreply, publish(state, :network, network(), &%Events.NetworkChanged{interfaces: &1})}
    end

    @impl GenServer
    def handle_info(%PropertyTable.Event{table: NervesUEvent} = event, state) do
      if sound?(event) do
        {:noreply, publish(state, :output, output(), &struct(Events.OutputChanged, &1))}
      else
        {:noreply, state}
      end
    end

    @impl GenServer
    def handle_info(%Ash.Notifier.Notification{}, %{settling?: true} = state) do
      {:noreply, state}
    end

    @impl GenServer
    def handle_info(%Ash.Notifier.Notification{}, state) do
      Process.send_after(self(), :storage, @settle)

      {:noreply, %{state | settling?: true}}
    end

    @impl GenServer
    def handle_info(:storage, state) do
      state = publish(state, :storage, storage(), &struct(Events.StorageChanged, &1))

      {:noreply, %{state | settling?: false}}
    end

    @impl GenServer
    def handle_info(_message, state), do: {:noreply, state}

    defp publish(state, key, report, event) do
      if Map.fetch!(state, key) == report do
        state
      else
        Event.publish(:device, event.(report))
        Map.put(state, key, report)
      end
    end

    defp network, do: Device.network!()

    defp output, do: Playback.output!()

    defp storage, do: Device.storage!()

    # A uevent names its subsystem in the map that it carries. A removal carries the map
    # that the property held before, because the property holds nothing now.
    defp sound?(%PropertyTable.Event{value: %{"subsystem" => "sound"}}), do: true
    defp sound?(%PropertyTable.Event{previous_value: %{"subsystem" => "sound"}}), do: true
    defp sound?(_event), do: false
  end
end
