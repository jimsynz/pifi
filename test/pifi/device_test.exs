defmodule PiFi.DeviceTest do
  @moduledoc """
  The reports of the hardware.

  **`:alarm_handler` is one process for the whole node**, and two tests here raise an
  alarm of it, so this file cannot run beside another that reads the free space.
  """

  use PiFi.DataCase, async: false

  alias PiFi.Device

  describe "storage/0" do
    test "reports each field of the shape that the action declares" do
      assert {:ok, report} = Device.storage()

      assert %{
               path: path,
               total_bytes: total,
               free_bytes: free,
               used_bytes: used,
               database_bytes: database
             } = report

      assert is_binary(path)
      assert is_integer(total) and total > 0
      assert is_integer(free) and free >= 0
      assert used == total - free
      assert is_integer(database) and database >= 0
    end

    test "names the partition that holds the database" do
      assert {:ok, %{path: path}} = Device.storage()

      database = PiFi.Repo.config() |> Keyword.fetch!(:database)

      assert path == Path.dirname(database)
    end

    # **`/` on a Nerves device is the read only squashfs of the firmware, and it is 100%
    # full by construction**, so `:disksup` raises this alarm at every boot. An earlier
    # version read that alarm as the partition of the database, whatever the path, and a
    # device told a person that the card was full with 28.0 GB free of 30.9 GB.
    test "an alarm of another partition is not this one" do
      alarm(~c"/nothing-of-this-device")

      assert {:ok, %{full?: false}} = Device.storage()
    end

    test "an alarm of this partition is this one" do
      assert {:ok, %{path: path}} = Device.storage()

      alarm(mount_of(path))

      assert {:ok, %{full?: true}} = Device.storage()
    end

    test "the free space is no more than the whole partition" do
      assert {:ok, %{total_bytes: total, free_bytes: free}} = Device.storage()

      assert free <= total
    end
  end

  # `:disksup` raises this for a mount point, and the report compares that mount point
  # with the one that `df` names for the database.
  defp alarm(mount) do
    :alarm_handler.set_alarm({{:disk_almost_full, mount}, []})

    on_exit(fn -> :alarm_handler.clear_alarm({:disk_almost_full, mount}) end)
  end

  # The mount point of a path, in the way that `df -P` gives it: the last field of the
  # record. A test reads it here so it holds no guess about the machine that it runs on.
  defp mount_of(path) do
    {output, 0} = System.cmd("df", ["-k", "-P", path])

    output
    |> String.split("\n", trim: true)
    |> Enum.at(1)
    |> String.split()
    |> List.last()
    |> String.to_charlist()
  end

  describe "network/0" do
    test "a host reports no interface" do
      # `vintage_net` is a target dependency, so the host build holds no
      # reference to it. A device reports each configured interface.
      assert {:ok, []} = Device.network()
    end
  end

  describe "the actions" do
    test "both run through the domain, so an API extension can serve them" do
      assert %{path: _path} = Device.storage!()
      assert is_list(Device.network!())
    end
  end
end
