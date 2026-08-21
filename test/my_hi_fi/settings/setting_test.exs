defmodule MyHiFi.Settings.SettingTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Settings

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
end
