defmodule MyHiFi.HardwareTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Hardware
  alias MyHiFi.Settings

  setup do
    on_exit(fn ->
      case Settings.fetch(Hardware.setting()) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end)

    :ok
  end

  describe "the profiles that this firmware knows" do
    test "each one holds an identifier, a name and its lines" do
      for profile <- Hardware.profiles() do
        assert is_binary(profile.id)
        assert is_binary(profile.title)
        assert is_binary(profile.description)
        assert is_list(profile.lines)
      end
    end

    test "the first one adds nothing, so a device with no board added needs no write" do
      assert %{id: "none", lines: []} = hd(Hardware.profiles())
    end

    # A DAC on the I2S pins needs the overlay and the pin that turns it on.
    test "the profile of a board on the I2S pins names the overlay" do
      assert %{lines: lines} = Enum.find(Hardware.profiles(), &(&1.id == "hifiberry-dac"))

      assert "dtoverlay=hifiberry-dac" in lines
      assert "gpio=25=op,dh" in lines
    end

    # `fwup.conf.eex` of the Nerves system writes only the overlays that it names, so a
    # profile that names one which is absent from that list loads nothing at all.
    test "every overlay of every profile is one that a person can add to that list" do
      for profile <- Hardware.profiles(),
          line <- profile.lines,
          String.starts_with?(line, "dtoverlay=") do
        assert line =~ ~r/\Adtoverlay=[a-z0-9-]+(,[^\s]+)?\z/
      end
    end
  end

  describe "the profile that a person chose" do
    test "a device that chose nothing holds the first profile" do
      assert Hardware.chosen().id == "none"
    end

    test "a choice comes back" do
      assert :ok = Hardware.choose("hifiberry-dac")

      assert Hardware.chosen().id == "hifiberry-dac"
    end

    test "a name that no profile holds changes nothing" do
      assert {:error, :no_such_profile} = Hardware.choose("nonsense")

      assert Hardware.chosen().id == "none"
    end

    # A later version may take a profile away, and the setting of a person then names
    # one that this firmware does not hold.
    test "a setting that names no profile of this firmware holds the first one" do
      {:ok, _setting} = Settings.put(Hardware.setting(), "removed-in-a-later-version")

      assert Hardware.chosen().id == "none"
    end
  end

  # The bootloader runs before Linux, so a host holds no `config.txt` and needs none.
  describe "on a host" do
    test "it writes no boot configuration and restarts nothing" do
      assert Hardware.reconcile() == :not_needed
    end
  end
end
