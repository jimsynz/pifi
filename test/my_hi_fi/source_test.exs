defmodule MyHiFi.SourceTest do
  use MyHiFi.DataCase, async: false

  doctest MyHiFi.Source, import: true

  alias MyHiFi.Settings
  alias MyHiFi.Source
  alias MyHiFi.Test.PlainSource

  setup do
    on_exit(fn ->
      keys =
        Enum.map([Source.InternetRadio, Source.Podcasts, PlainSource], &Source.enabled_key/1)

      for key <- [Source.chosen_key() | keys] do
        case Settings.fetch(key) do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end
    end)

    :ok
  end

  describe "which sources are in use" do
    test "a source that no person changed is in use" do
      assert Source.enabled?(Source.InternetRadio)
      assert Source.enabled() == Source.all()
    end

    test "a source out of use leaves the list, and it stays in `all/0`" do
      Source.enable(Source.Podcasts, false)

      refute Source.enabled?(Source.Podcasts)
      assert Source.enabled() == [Source.InternetRadio, Source.Jellyfin]
      assert Source.Podcasts in Source.all()
    end

    test "a source comes back" do
      Source.enable(Source.Podcasts, false)
      Source.enable(Source.Podcasts, true)

      assert Source.enabled?(Source.Podcasts)
    end

    test "the key holds the name of the source in an address" do
      assert Source.enabled_key(Source.Podcasts) == "source.podcasts.enabled"
    end
  end

  # The top row of the faceplate is the source switch of this device, and a switch
  # stays where a hand put it. See `MyHiFi.Source.chosen/0`.
  describe "the source that a person chose" do
    test "a device that no person has used lands on the first source in use" do
      assert Source.chosen() == Source.InternetRadio
    end

    test "a choice stays, and it survives a restart because it is a row" do
      Source.choose(Source.Podcasts)

      assert Source.chosen() == Source.Podcasts
      assert {:ok, %{value: "podcasts"}} = Settings.fetch(Source.chosen_key())
    end

    test "a second choice of the same source writes nothing" do
      Source.choose(Source.Podcasts)
      {:ok, first} = Settings.fetch(Source.chosen_key())

      Source.choose(Source.Podcasts)

      assert {:ok, ^first} = Settings.fetch(Source.chosen_key())
    end

    test "a choice that a person took out of use gives the first source in use" do
      Source.choose(Source.Podcasts)
      Source.enable(Source.Podcasts, false)

      assert Source.chosen() == Source.InternetRadio
    end

    # A firmware that drops a source leaves the name of it in the settings, and the
    # device must still answer with something.
    test "a name that no source holds gives the first source in use" do
      Settings.put!(Source.chosen_key(), "a-source-that-went")

      assert Source.chosen() == Source.InternetRadio
    end

    test "a device with no source in use chooses none" do
      for module <- Source.all(), do: Source.enable(module, false)

      assert Source.chosen() == nil
    end
  end

  describe "the settings of a source" do
    test "a source that implements none holds no field and no control" do
      assert Source.settings(PlainSource) == []
      assert Source.settings_actions(PlainSource) == []
    end

    test "a write to a source that holds no settings says so" do
      assert {:error, message} = Source.put_settings(PlainSource, %{"key" => "value"})
      assert message =~ "nothing to change"
    end

    test "a control that a source does not hold says so" do
      assert {:error, message} = Source.run_settings_action(PlainSource, "sync")
      assert message =~ "no such control"
    end

    test "each field of a source names itself and gives a type" do
      for module <- Source.all(), field <- Source.settings(module) do
        assert is_binary(field.key)
        assert is_binary(field.title)
        # Each one is a type that `MyHiFiWeb.CoreComponents.input/1` draws, and the
        # settings page passes it through without a rule of its own.
        assert field.type in [:number, :password, :text]
        assert is_boolean(field.write_only?)
      end
    end

    test "a write-only field gives no value, so nothing reaches a browser" do
      for module <- Source.all(),
          field <- Source.settings(module),
          field.write_only? do
        assert field.value == nil
      end
    end

    test "each control of a source names itself" do
      for module <- Source.all(), action <- Source.settings_actions(module) do
        assert is_binary(action.name)
        assert is_binary(action.title)
        assert is_atom(action.icon)
      end
    end
  end
end
