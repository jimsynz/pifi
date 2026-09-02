defmodule MyHiFi.SwitchOffTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Event
  alias MyHiFi.Event.Device, as: Events
  alias MyHiFi.Event.Player
  alias MyHiFi.Settings
  alias MyHiFi.SwitchOff

  doctest MyHiFi.SwitchOff, import: true

  setup do
    :ok = Event.subscribe(:device)

    # `prepare/1` pauses every queue of Oban, and Oban is one instance for the whole
    # node. A test that left them paused would leave every test after it with a queue
    # that runs nothing.
    on_exit(fn ->
      try do
        Oban.resume_all_queues()
      catch
        :exit, _reason -> :ok
      end
    end)

    on_exit(fn ->
      case Settings.fetch(SwitchOff.key()) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end)

    :ok
  end

  # `MyHiFi.Application` starts none of these in the test environment, so a test holds
  # the one that it asks for. See `MyHiFi.Application.listening_children/0`.
  defp start_switch_off(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:drain_ms, 200)
      |> Keyword.put_new(:checkpoint_ms, :timer.hours(1))

    start_supervised!({SwitchOff, opts})
  end

  describe "whether this device prepares to be switched off" do
    # The device on a stereo is the one that a firmware cannot ask about, and its
    # background work runs while it stands in standby.
    test "a device that no person changed does not" do
      refute SwitchOff.enabled?()
    end

    test "a person turns it on and off" do
      assert :ok = SwitchOff.enable(true)
      assert SwitchOff.enabled?()

      assert :ok = SwitchOff.enable(false)
      refute SwitchOff.enabled?()
    end
  end

  describe "prepare/1" do
    test "it says that the device is safe when nothing runs" do
      assert :ok = SwitchOff.prepare(200)

      assert_receive %Events.SafeToSwitchOff{safe?: true}
    end

    # The fsync of this file is what commits the journal of the file system, because
    # there is no `sync` in the busybox of this system.
    test "it writes the marker and syncs it" do
      File.rm(SwitchOff.marker())

      assert :ok = SwitchOff.prepare(200)

      assert {:ok, written} = File.read(SwitchOff.marker())
      assert {:ok, _at, _offset} = DateTime.from_iso8601(written)
    end

    # A sandbox holds the database in a transaction that never commits, so a checkpoint
    # inside a test answers "database table is locked" and says nothing about a device.
    # `prepare/1` writes that to the log and goes on, and the board is where the
    # checkpoint is read.
    test "a checkpoint that cannot run does not stop the rest" do
      assert :ok = SwitchOff.prepare(200)

      assert_receive %Events.SafeToSwitchOff{safe?: true}
    end
  end

  describe "the standby of the player" do
    test "a device that prepares says that it is safe" do
      :ok = SwitchOff.enable(true)
      start_switch_off()

      Event.publish(:player, %Player.Standby{entered?: true})

      assert_receive %Events.SafeToSwitchOff{safe?: true}, 5000
    end

    # One image runs on a stereo and on a portable device, and the stereo wants its
    # background work to go on while it stands in standby.
    test "a device that does not prepare says nothing at all" do
      start_switch_off()

      Event.publish(:player, %Player.Standby{entered?: true})

      refute_receive %Events.SafeToSwitchOff{}, 500
    end

    # The moment that a person wakes the device is the moment that the card is no longer
    # at rest, so nothing must still say that it is.
    test "a person who wakes the device takes the answer away" do
      :ok = SwitchOff.enable(true)
      start_switch_off()

      Event.publish(:player, %Player.Standby{entered?: true})
      assert_receive %Events.SafeToSwitchOff{safe?: true}, 5000

      Event.publish(:player, %Player.Standby{entered?: false})

      assert_receive %Events.SafeToSwitchOff{safe?: false}, 5000
    end

    test "an event of the player that is not a standby says nothing" do
      :ok = SwitchOff.enable(true)
      start_switch_off()

      Event.publish(:player, %Player.Stopped{reason: :requested})

      refute_receive %Events.SafeToSwitchOff{}, 500
    end
  end

  # A cell that dies faster than the warning, a switch that a hand reaches with no press
  # of standby, and a fault all take the power with no preparation. A checkpoint on a
  # period bounds what a device loses to that period, and `synchronous: :full` would
  # bound it to nothing at 32 times the cost of a commit. See the moduledoc.
  describe "the checkpoint of the period" do
    setup do
      parent = self()

      :ok =
        :telemetry.attach(
          "switch-off-test-#{System.unique_integer([:positive])}",
          [:my_hi_fi, :repo, :query],
          fn _name, _measure, %{query: query}, _config ->
            if query =~ "wal_checkpoint", do: send(parent, {:checkpointed, query})
          end,
          nil
        )

      on_exit(fn ->
        for %{id: id} <- :telemetry.list_handlers([:my_hi_fi, :repo, :query]),
            is_binary(id) and String.starts_with?(id, "switch-off-test-"),
            do: :telemetry.detach(id)
      end)

      :ok
    end

    # A power cut reaches a device on the mains as well, so no person turns this off.
    test "it runs whether or not this device prepares to be switched off" do
      refute SwitchOff.enabled?()

      start_switch_off(checkpoint_ms: 50)

      assert_receive {:checkpointed, query}, 2000
      assert query =~ "PASSIVE"
    end

    # The passive one never waits for a reader, so it can never hold a track that plays.
    # The standby empties the log instead, because the device is going quiet.
    test "the period is passive and a standby truncates" do
      :ok = SwitchOff.enable(true)
      start_switch_off(checkpoint_ms: :timer.hours(1))

      Event.publish(:player, %Player.Standby{entered?: true})

      assert_receive {:checkpointed, query}, 5000
      assert query =~ "TRUNCATE"
    end

    test "a checkpoint that cannot run answers ok and writes the reason" do
      assert :ok = SwitchOff.checkpoint(:passive)
      assert :ok = SwitchOff.checkpoint(:truncate)
    end
  end
end
