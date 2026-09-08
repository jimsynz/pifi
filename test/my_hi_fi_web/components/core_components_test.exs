defmodule MyHiFiWeb.CoreComponentsTest do
  @moduledoc false
  use MyHiFiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MyHiFiWeb.CoreComponents

  describe "flash/1" do
    test "a notice holds the hook that removes it after a period" do
      html =
        render_component(&CoreComponents.flash/1, kind: :info, flash: %{"info" => "It plays."})

      assert html =~ ~s(phx-hook="Flash")
      assert html =~ "It plays."
    end

    test "no notice draws no element" do
      html = render_component(&CoreComponents.flash/1, kind: :info, flash: %{})

      refute html =~ "role=\"alert\""
    end
  end
end
