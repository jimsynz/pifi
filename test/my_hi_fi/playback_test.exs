defmodule MyHiFi.PlaybackTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Playback
  alias MyHiFi.Settings
  alias MyHiFi.Test.NoCardOutput
  alias MyHiFi.Test.Stations

  defp station(overrides), do: Stations.create(overrides)

  setup do
    reset = fn ->
      Playback.stop!()
      Playback.standby!(false)

      for key <- ["standby", "last_source", "last_ref", "output_device"] do
        case Settings.fetch(key) do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end
    end

    reset.()
    on_exit(reset)
    :ok
  end

  describe "state/0" do
    test "gives each field of the shape that the action declares" do
      assert {:ok, state} = Playback.state()

      assert %{
               source: _source,
               item: _item,
               stream_title: _title,
               artwork_path: _path,
               playing?: playing?,
               standby?: standby?,
               position_ms: position
             } = state

      assert is_boolean(playing?)
      assert is_boolean(standby?)
      assert is_integer(position)
    end
  end

  describe "stop/0" do
    test "gives :ok, and the player then plays nothing" do
      assert Playback.stop!() == :ok
      assert %{playing?: false, item: nil} = Playback.state!()
    end
  end

  describe "standby/1" do
    test "enters standby and leaves it" do
      assert Playback.standby!(true) == :ok
      assert %{standby?: true} = Playback.state!()

      assert Playback.standby!(false) == :ok
      assert %{standby?: false} = Playback.state!()
    end

    test "refuses an argument that is not a boolean" do
      assert_raise Ash.Error.Invalid, fn -> Playback.standby!("yes") end
    end
  end

  describe "play/2" do
    # **A play answers before it starts, so the reason arrives on the `:player` topic
    # and not in the answer.** A resolve reads the service of the source, and a person
    # must not wait for that with a page that can draw nothing. See
    # `MyHiFi.Player.handle_call({:play, _}, _, _)`.
    test "gives the reason when a track cannot play" do
      # An output that finds no card makes this fail on any machine. See
      # `MyHiFi.Test.NoCardOutput`.
      NoCardOutput.use_it()

      created = station(%{})

      Event.subscribe(:player)

      assert {:ok, :ok} = Playback.play([created.id])
      assert_receive %Events.Failed{reason: :no_output_device}, 2000
    end

    test "it needs a list of items" do
      assert_raise Ash.Error.Invalid, fn -> Playback.play!(nil) end
    end

    # A person who presses a track of a list means "play this, and then the rest of the
    # list", so the whole list goes in the queue and the row that they pressed takes the
    # mark.
    test "the list goes in the queue, and the row that a person pressed takes the mark" do
      NoCardOutput.use_it()
      first = station(%{title: "First"})
      second = station(%{title: "Second"})

      Playback.play([first.id, second.id], %{playing_index: 1})

      assert [one, two] = Playback.queue!()
      assert one.item_id == first.id
      assert two.item_id == second.id
      assert two.playing? == true
    end
  end

  describe "output/0 and select_output/1" do
    test "gives the devices and the choice" do
      assert %{devices: devices, selected: _selected} = Playback.output!()
      assert is_list(devices)
    end

    test "keeps a choice, and the state shows it" do
      assert Playback.select_output!("Audio") == :ok
      assert %{selected: "Audio"} = Playback.output!()
    end

    test "refuses an id that is not a string" do
      assert_raise Ash.Error.Invalid, fn -> Playback.select_output!(42) end
    end
  end

  describe "the domain" do
    test "holds every control, so no page calls the process" do
      # `MyHiFi.Player` is the process, and each page calls this domain instead.
      for {name, arity} <- [
            state: 0,
            play: 2,
            stop: 0,
            standby: 1,
            output: 0,
            select_output: 1
          ] do
        assert function_exported?(Playback, name, arity),
               "MyHiFi.Playback.#{name}/#{arity} is absent"
      end
    end
  end
end
