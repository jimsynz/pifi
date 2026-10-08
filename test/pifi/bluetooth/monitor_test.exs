defmodule PiFi.Bluetooth.MonitorTest do
  use PiFi.DataCase, async: false

  doctest PiFi.Bluetooth.Monitor

  alias PiFi.Bluetooth.Monitor
  alias PiFi.Event
  alias PiFi.Event.Source.EnabledChanged
  alias PiFi.Settings
  alias PiFi.Source
  alias PiFi.Test.PlayingPipeline
  alias PiFi.Test.SilentOutput
  alias PiFi.Test.Stations

  setup do
    drain = fn ->
      PiFi.Player.stop()
      PiFi.Player.state()
    end

    drain.()

    on_exit(fn ->
      case Settings.fetch(Source.enabled_key(Source.Bluetooth)) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end)

    on_exit(drain)

    :ok
  end

  # **`MediaControl1` carries a `Connected` of its own** and it means something else:
  # whether the remote control of a player is up, not whether the device is. Reading it
  # as the device's would start a telephone that never connected.
  describe "which signals say a device came or went" do
    test "a device that connected is one" do
      assert Monitor.connection_signal?(
               "org.freedesktop.DBus.Properties",
               "PropertiesChanged",
               {"org.bluez.Device1", %{"Connected" => false}, []}
             )
    end

    test "a battery level is not" do
      refute Monitor.connection_signal?(
               "org.freedesktop.DBus.Properties",
               "PropertiesChanged",
               {"org.bluez.Device1", %{"Percentage" => 80}, []}
             )
    end

    # **The body arrives as a tuple and not a list**, which a board reported and a
    # clause written for a list matched none of.
    test "a shape this does not read is not" do
      refute Monitor.connection_signal?(
               "org.freedesktop.DBus.Properties",
               "PropertiesChanged",
               ["org.bluez.Device1", %{"Connected" => true}]
             )
    end

    test "a signal that is not a property change is not" do
      refute Monitor.connection_signal?(
               "org.freedesktop.DBus.ObjectManager",
               "InterfacesAdded",
               {"org.bluez.Device1", %{"Connected" => true}, []}
             )
    end
  end

  describe "what it does with the music" do
    # **It is a child of the application now**, because the switch it watches is how the
    # radio starts and a monitor that only ran while the daemons did could not do that.
    setup do
      assert is_pid(Process.whereis(Monitor))

      :ok
    end

    # **Only a telephone that this device is playing may stop it.** A disconnect that
    # arrived while a person was listening to a podcast would take their music away.
    test "a person turning the source off leaves other music alone" do
      PlayingPipeline.use_it()
      SilentOutput.use_it()
      station = Stations.create(%{country_code: "NZ", title: "RNZ National"})

      {:ok, :ok} = PiFi.Playback.play([station.id])
      assert eventually(fn -> PiFi.Playback.state!().playing? end)

      Event.publish(:source, %EnabledChanged{source: Source.Bluetooth, enabled?: false})

      refute eventually(fn -> not PiFi.Playback.state!().playing? end, 5)
    end

    # **A person who turns this on and finds nothing has been told nothing**, so the
    # source switch is what starts the radio. A machine that is not the board has no
    # adapter, which is the branch this reaches, and the point is that it says so and
    # carries on rather than raising on a laptop.
    test "turning the source on asks for the radio" do
      refute PiFi.Bluetooth.enabled?()

      Event.publish(:source, %EnabledChanged{source: Source.Bluetooth, enabled?: true})

      refute eventually(fn -> not Process.alive?(Process.whereis(Monitor)) end, 5)
    end

    # The radio is shared with the headphones a person may be listening to, so taking
    # the source out of use must not stop the daemons.
    test "turning the source off leaves the radio alone" do
      Event.publish(:source, %EnabledChanged{source: Source.Bluetooth, enabled?: false})

      refute eventually(fn -> not Process.alive?(Process.whereis(Monitor)) end, 5)
    end

    # Nothing is connected in a test, so this is the case where a signal arrives and
    # there is nothing behind it. It must not start anything and it must not fall over.
    test "a connection change with no telephone behind it plays nothing" do
      assert :ok = Monitor.connection_changed()

      refute eventually(fn -> PiFi.Playback.state!().playing? end, 5)
      assert Process.alive?(Process.whereis(Monitor))
    end
  end

  # Bluetooth is off on a device nobody asked for it, so the watcher calls this whether
  # the daemons are running or not.
  test "it answers rather than exiting when there is nothing behind it" do
    assert :ok = Monitor.connection_changed()
  end

  defp eventually(check, attempts \\ 100)

  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end
end
