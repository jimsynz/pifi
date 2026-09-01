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

    This process also starts ntpd again when a connection reaches the internet. It holds
    the network events already, and a second subscriber of the same property would do
    that work twice. The comment on `restart_ntpd/1` holds the fault of busybox ntpd
    that makes this necessary.

    The first read does that work as well, and the event alone is not enough. This
    process is the second to last child of `MyHiFi.Application`, so it starts about six
    seconds after the boot, and VintageNet reports `:internet` about half a second after
    the boot. A log of 14 boots of one device held the event 3 times, and the 3 are the
    boots where Wi-Fi took 8 seconds more than usual. On the other 11 the clock stayed
    wrong until a person set it.
    """

    use GenServer

    require Logger

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
      if internet?(), do: restart_ntpd("The network already reaches the internet")

      {:noreply, %{state | network: network(), output: output(), storage: storage()}}
    end

    @impl GenServer
    def handle_info({VintageNet, property, old, new, _metadata}, state) do
      restart_ntpd(property, old, new)

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

    # `NervesTime` starts ntpd 10 ms after the boot, and Wi-Fi associates later than
    # that. busybox ntpd reads the address of each pool server one time, at its start,
    # so a start with no DNS leaves the daemon with no server. It then runs and sets no
    # clock, and the board holds the time of the last shutdown until something starts
    # the daemon again.
    #
    # A connection that reaches `:internet` is the first moment that a read of an
    # address can succeed, so the daemon starts again there. A clock that is already
    # right needs nothing. The Podcast Index refuses a request from a board whose clock
    # is not right, so this is what makes a podcast work on a cold start. See
    # `MyHiFi.Podcast.Index`.
    #
    # The message names the caller, because two paths reach this and a log of one boot
    # must say which one ran.
    defp restart_ntpd(message) do
      if NervesTime.synchronized?() do
        :ok
      else
        Logger.info("#{message}, and the clock is not right yet.")

        NervesTime.restart_ntpd()
      end
    end

    defp restart_ntpd(["interface", _name, "connection"], old, :internet) when old != :internet,
      do: restart_ntpd("The network reached the internet")

    defp restart_ntpd(_property, _old, _new), do: :ok

    # A subscriber learns nothing about a property that already holds its value, so the
    # first read asks for the value itself. See `PropertyTable.subscribe/2`.
    defp internet? do
      ["interface", :_, "connection"]
      |> VintageNet.match()
      |> Enum.any?(&match?({_property, :internet}, &1))
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
