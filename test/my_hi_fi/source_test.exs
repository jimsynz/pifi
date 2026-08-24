defmodule MyHiFi.SourceTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Settings
  alias MyHiFi.Source
  alias MyHiFi.Test.PlainSource

  setup do
    on_exit(fn ->
      for module <- [Source.InternetRadio, Source.Podcasts, PlainSource] do
        case Settings.fetch(Source.enabled_key(module)) do
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
      assert Source.enabled() == [Source.InternetRadio]
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
        assert field.type in [:text, :password]
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
