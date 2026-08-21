defmodule MyHiFi.DeviceTest do
  use MyHiFi.DataCase, async: true

  alias MyHiFi.Device

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

      database = MyHiFi.Repo.config() |> Keyword.fetch!(:database)

      assert path == Path.dirname(database)
    end

    test "the free space is no more than the whole partition" do
      assert {:ok, %{total_bytes: total, free_bytes: free}} = Device.storage()

      assert free <= total
    end
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
