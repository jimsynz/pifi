defmodule PiFi.Settings.SettingTest do
  use PiFi.DataCase, async: false

  alias PiFi.Settings
  alias PiFi.Settings.Cache
  alias PiFi.Settings.Setting

  describe "put and fetch" do
    test "writes a value and reads it again" do
      Settings.put!("output_device", "Audio")

      assert {:ok, %{key: "output_device", value: "Audio"}} = Settings.fetch("output_device")
    end

    test "a second put replaces the value and keeps one row" do
      first = Settings.put!("station_countries", "NZ")
      second = Settings.put!("station_countries", "NZ,AU")

      assert second.id == first.id
      assert second.value == "NZ,AU"
      assert [_only_one] = Settings.list_settings!()
    end

    test "fetch gives an error for a key that is absent" do
      assert {:error, _reason} = Settings.fetch("nothing")
    end
  end

  describe "delete" do
    test "removes a setting" do
      Settings.put!("standby", "true")
      {:ok, setting} = Settings.fetch("standby")

      Settings.delete!(setting)

      assert {:error, _reason} = Settings.fetch("standby")
    end
  end

  # **The memory of `PiFi.Settings.Cache` is what these read.** A row that arrives
  # behind `PiFi.Settings` is the probe: the answer that a caller gets does not
  # move for it, and it moves as soon as the memory goes. Nothing of this firmware
  # writes such a row, and these tests say why nothing may.
  describe "the answers in memory" do
    test "a key that a row holds is read one time" do
      Settings.put!("standby", "true")
      write_behind("standby", "false")

      assert {:ok, %{value: "true"}} = Settings.fetch("standby")

      Cache.clear()

      assert {:ok, %{value: "false"}} = Settings.fetch("standby")
    end

    # A source that a person never chose is the usual case, and a page asks for one on
    # each navigation.
    test "a key that no row holds is read one time as well" do
      assert {:error, _reason} = Settings.fetch("standby")

      write_behind("standby", "true")

      assert {:error, _reason} = Settings.fetch("standby")

      Cache.clear()

      assert {:ok, %{value: "true"}} = Settings.fetch("standby")
    end

    test "a write moves what a read gives" do
      write_behind("standby", "true")
      assert {:ok, %{value: "true"}} = Settings.fetch("standby")

      Settings.put!("standby", "false")

      assert {:ok, %{value: "false"}} = Settings.fetch("standby")
    end

    test "a delete moves what a read gives" do
      setting = Settings.put!("standby", "true")

      Settings.delete!(setting)

      assert {:error, _reason} = Settings.fetch("standby")
    end
  end

  defp write_behind(key, value) do
    Setting
    |> Ash.Changeset.for_create(:put, %{key: key, value: value})
    |> Ash.create!()
  end
end
