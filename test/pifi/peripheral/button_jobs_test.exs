defmodule PiFi.Peripheral.ButtonJobsTest do
  # The settings cache is one table for the whole VM, so a test that writes a setting
  # can't run beside one that reads it.
  use PiFi.DataCase, async: false

  alias PiFi.Event.Input
  alias PiFi.Peripheral.ButtonJobs
  alias PiFi.Peripheral.PirateAudio
  alias PiFi.Peripheral.PiTft
  alias PiFi.Settings

  describe "settings/1" do
    test "each button has a press and a hold, with the menu closed and open" do
      keys = PirateAudio |> ButtonJobs.settings() |> Enum.map(& &1.key)

      assert keys == [
               "button_1_press",
               "button_1_hold",
               "button_1_menu_press",
               "button_1_menu_hold",
               "button_2_press",
               "button_2_hold",
               "button_2_menu_press",
               "button_2_menu_hold"
             ]
    end

    test "a button that no person changed shows the board's default" do
      field = PiTft |> ButtonJobs.settings() |> Enum.find(&(&1.key == "button_3_hold"))

      assert field.value == "open_menu"
      assert field.type == :select
      assert {"none", "Nothing"} in field.options
    end
  end

  describe "put_settings/2" do
    test "a job that a person chose is the one the button does" do
      assert {:ok, "Saved the buttons."} =
               ButtonJobs.put_settings(PiTft, %{"button_2_press" => "play_pause"})

      assert %Input.ButtonPressed{function: :play_pause} = ButtonJobs.pressed(PiTft, 2, :short)
      assert {:ok, %{value: "play_pause"}} = Settings.fetch("peripheral.pi-tft.button_2_press")
    end

    test "a value that isn't a job keeps nothing" do
      assert {:error, "That isn't a job a button can do."} =
               ButtonJobs.put_settings(PiTft, %{
                 "button_1_press" => "none",
                 "button_2_press" => "self_destruct"
               })

      assert %Input.ButtonPressed{function: :standby} = ButtonJobs.pressed(PiTft, 1, :short)
    end

    test "a key that isn't a button of the board is ignored" do
      assert {:ok, _message} = ButtonJobs.put_settings(PirateAudio, %{"button_3_press" => "next"})
      assert {:error, _not_found} = Settings.fetch("peripheral.pirate-audio.button_3_press")
    end
  end

  describe "pressed/3" do
    test "a press carries the jobs for the menu closed and open" do
      assert %Input.ButtonPressed{
               peripheral: PiTft,
               button: 4,
               hold: :short,
               function: :next,
               menu_function: :row_down
             } = ButtonJobs.pressed(PiTft, 4, :short)
    end

    test "a hold carries the jobs of a hold" do
      assert %Input.ButtonPressed{hold: :long, function: :standby, menu_function: :standby} =
               ButtonJobs.pressed(PirateAudio, 1, :long)
    end

    test "a button the board doesn't have does nothing" do
      assert %Input.ButtonPressed{function: :none, menu_function: :none} =
               ButtonJobs.pressed(PirateAudio, 3, :short)
    end

    # A later version might drop a job, and a button must not be left doing something
    # unknown.
    test "a stored value that is no longer a job reads as the default" do
      Settings.put!("peripheral.pi-tft.button_1_press", "self_destruct")

      assert %Input.ButtonPressed{function: :standby} = ButtonJobs.pressed(PiTft, 1, :short)
    end
  end
end
