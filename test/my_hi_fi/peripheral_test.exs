defmodule MyHiFi.PeripheralTest do
  @moduledoc """
  What a person turns on, and what the board answers.

  `MyHiFi.Peripheral.Supervisor` is one process for the whole firmware, and a
  peripheral registers under the name of its module, so these cannot run at the same
  time as each other.
  """

  use MyHiFi.DataCase, async: false

  alias MyHiFi.Peripheral
  alias MyHiFi.Test.Lamp

  doctest MyHiFi.Peripheral, import: true

  setup do
    on_exit(fn ->
      Peripheral.stop(Lamp)
      Application.delete_env(:my_hi_fi, :peripherals)
    end)

    :ok
  end

  describe "which peripherals a device holds" do
    test "all/0 gives what the configuration names" do
      knows([{Lamp, []}])

      assert Peripheral.all() == [{Lamp, []}]
    end

    test "a firmware that names none holds none" do
      assert Peripheral.all() == []
    end

    test "from_slug/1 finds one by its name" do
      knows([{Lamp, []}])

      assert Peripheral.from_slug("lamp") == {:ok, Lamp}
    end

    test "from_slug/1 refuses a name that no peripheral holds" do
      knows([{Lamp, []}])

      assert Peripheral.from_slug("gramophone") == {:error, :not_a_peripheral}
    end
  end

  describe "whether a peripheral is in use" do
    test "a peripheral that no person changed is out of use" do
      knows([{Lamp, []}])

      refute Peripheral.enabled?(Lamp)
    end

    test "it keeps what a person asked for" do
      knows([{Lamp, []}])

      assert :ok = Peripheral.enable(Lamp, true)
      assert Peripheral.enabled?(Lamp)

      assert :ok = Peripheral.enable(Lamp, false)
      refute Peripheral.enabled?(Lamp)
    end
  end

  describe "turning one on and off" do
    test "it starts the process, so a screen lights up with no restart" do
      knows([{Lamp, []}])

      assert :ok = Peripheral.enable(Lamp, true)
      assert Peripheral.running?(Lamp)
      assert is_pid(Process.whereis(Lamp))
    end

    test "it gives the options of the configuration to the peripheral" do
      knows([{Lamp, report_to: self()}])

      :ok = Peripheral.enable(Lamp, true)
      :ok = Peripheral.enable(Lamp, false)

      assert_receive {:lamp_terminated, :shutdown}
    end

    test "it stops the process, and terminate runs so a screen goes dark" do
      knows([{Lamp, report_to: self()}])

      :ok = Peripheral.enable(Lamp, true)

      assert :ok = Peripheral.enable(Lamp, false)

      assert_receive {:lamp_terminated, :shutdown}
      refute Peripheral.running?(Lamp)
      refute Process.whereis(Lamp)
    end

    test "a second start of one that already runs changes nothing" do
      knows([{Lamp, []}])

      :ok = Peripheral.enable(Lamp, true)
      pid = Process.whereis(Lamp)

      assert :ok = Peripheral.start(Lamp)
      assert Process.whereis(Lamp) == pid
    end

    test "a stop of one that runs no more gives :ok" do
      knows([{Lamp, []}])

      assert :ok = Peripheral.stop(Lamp)
    end
  end

  describe "hardware that does not answer" do
    test "the error reaches the caller, so a page can show it" do
      knows([{Lamp, fault: :no_such_device}])

      assert {:error, :no_such_device} = Peripheral.enable(Lamp, true)
    end

    test "the setting stays, so a part that a person wires later comes up" do
      knows([{Lamp, fault: :no_such_device}])

      {:error, :no_such_device} = Peripheral.enable(Lamp, true)

      assert Peripheral.enabled?(Lamp)
      refute Peripheral.running?(Lamp)
    end

    test "a start that failed does not keep the next one from working" do
      knows([{Lamp, fault: :no_such_device}])
      {:error, :no_such_device} = Peripheral.enable(Lamp, true)

      knows([{Lamp, []}])

      assert :ok = Peripheral.start(Lamp)
      assert Peripheral.running?(Lamp)
    end
  end

  describe "start_enabled/0" do
    test "it starts the peripherals that a person put in use" do
      knows([{Lamp, []}])
      :ok = Peripheral.enable(Lamp, true)
      :ok = Peripheral.stop(Lamp)

      assert :ok = Peripheral.start_enabled()
      assert Peripheral.running?(Lamp)
    end

    test "it starts nothing that a person left out of use" do
      knows([{Lamp, []}])

      assert :ok = Peripheral.start_enabled()
      refute Peripheral.running?(Lamp)
    end

    test "hardware that does not answer stops no other start" do
      knows([{Lamp, fault: :no_such_device}])
      MyHiFi.Settings.put!(Peripheral.enabled_key(Lamp), "true")

      assert :ok = Peripheral.start_enabled()
      refute Peripheral.running?(Lamp)
    end
  end

  defp knows(peripherals), do: Application.put_env(:my_hi_fi, :peripherals, peripherals)
end
