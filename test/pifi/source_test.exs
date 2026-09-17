defmodule PiFi.SourceTest do
  use PiFi.DataCase, async: false

  doctest PiFi.Source, import: true

  alias PiFi.Podcast.Index
  alias PiFi.Settings
  alias PiFi.Source
  alias PiFi.Test.PlainSource

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
    test "a source that no person changed, and that needs nothing, is in use" do
      assert Source.enabled?(Source.InternetRadio)
      assert Source.enabled() == [Source.InternetRadio]
    end

    test "a source that needs setup is out of use until a person sets it up" do
      refute Source.enabled?(Source.Podcasts)

      give_index_a_key()

      assert Source.enabled?(Source.Podcasts)
      assert Source.enabled() == [Source.InternetRadio, Source.Podcasts]
    end

    test "a source that a person took out of use stays out after they set it up" do
      Source.enable(Source.Podcasts, false)
      give_index_a_key()

      refute Source.enabled?(Source.Podcasts)
    end

    test "a source out of use leaves the list, and it stays in `all/0`" do
      Source.enable(Source.InternetRadio, false)

      refute Source.enabled?(Source.InternetRadio)
      assert Source.enabled() == []
      assert Source.InternetRadio in Source.all()
    end

    test "a source comes back" do
      Source.enable(Source.InternetRadio, false)
      Source.enable(Source.InternetRadio, true)

      assert Source.enabled?(Source.InternetRadio)
    end

    test "a person can put a source that is not ready in use" do
      Source.enable(Source.Podcasts, true)

      assert Source.enabled?(Source.Podcasts)
    end

    test "the key holds the name of the source in an address" do
      assert Source.enabled_key(Source.Podcasts) == "source.podcasts.enabled"
    end
  end

  # The top row of the faceplate is the source switch of this device, and a switch
  # stays where a hand put it. See `PiFi.Source.chosen/0`.
  describe "the source that a person chose" do
    test "a device that no person has used lands on the first source in use" do
      assert Source.chosen() == Source.InternetRadio
    end

    test "a choice stays, and it survives a restart because it is a row" do
      Source.enable(Source.Podcasts, true)
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
        # Each one is a type that `PiFiWeb.CoreComponents.input/1` draws, and the
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

  describe "the groups of a search" do
    test "a source that names none gets one group for each of its kinds" do
      labels = Enum.map(Source.search_groups(Source.Podcasts, ""), &elem(&1, 0))

      assert labels == ["Shows", "Episodes"]
    end

    test "a source of one kind gets one group" do
      labels = Enum.map(Source.search_groups(Source.InternetRadio, ""), &elem(&1, 0))

      assert labels == ["Stations"]
    end

    # An artist and an album are both containers, so `kinds/0` cannot tell them apart.
    test "a library names its own groups, and they are finer than its kinds" do
      for module <- [Source.Jellyfin, Source.Plex] do
        labels = Enum.map(Source.search_groups(module, ""), &elem(&1, 0))

        assert labels == ["Artists", "Albums", "Tracks"]
      end
    end

    test "a source that offers no search holds no group" do
      assert Source.search_groups(PlainSource, "") == []
    end

    test "each group names a query and a kind of row" do
      for module <- Source.all(), {label, listing} <- Source.search_groups(module, "") do
        assert is_binary(label)
        assert %Ash.Query{} = listing.query
        assert listing.kind == :item
      end
    end
  end

  # Podcasts is ready when it holds a key of the Podcast Index, and that is the setup
  # that puts the source in use. See `PiFi.Source.enabled?/1`.
  defp give_index_a_key do
    Settings.put!(Index.key_setting(), "a-key")
    Settings.put!(Index.secret_setting(), "a-secret")

    :ok
  end
end
