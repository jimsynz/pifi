defmodule MyHiFiWeb.ShellTest do
  # The pages read `MyHiFi.Player`, which one process holds for the whole node.
  use MyHiFiWeb.ConnCase, async: false

  alias MyHiFi.Event
  alias MyHiFi.Event.Input

  # The root address redirects to the first source in use, and a redirect is a page
  # load of its own. This test names the page that a person lands on.
  @radio "/browse/internet-radio"

  setup do
    :ok = Event.subscribe(:input)
    :ok
  end

  # A page load sends one event, so a test that measures a click must take that one
  # out of the mailbox first.
  defp drain do
    receive do
      %Input.PageUsed{} -> drain()
    after
      100 -> :ok
    end
  end

  describe "what a person does on a page" do
    test "a page that a person loads sends one event", %{conn: conn} do
      {:ok, _view, _html} = live(conn, @radio)

      assert_receive %Input.PageUsed{page: MyHiFiWeb.BrowseLive}

      # `MyHiFiWeb.Layouts` renders the faceplate inside the page, and the router
      # renders it never, so it holds no `:handle_params` and it sends nothing here.
      refute_receive %Input.PageUsed{}, 100
    end

    test "a click sends an event", %{conn: conn} do
      {:ok, view, _html} = live(conn, @radio)

      drain()

      view |> element("#open-0") |> render_click()

      assert_receive %Input.PageUsed{page: MyHiFiWeb.BrowseLive}
    end

    test "a control of the faceplate names the faceplate", %{conn: conn} do
      {:ok, view, _html} = live(conn, @radio)

      drain()

      view |> find_live_child("player") |> element("#artwork-button") |> render_click()

      assert_receive %Input.PageUsed{page: MyHiFiWeb.PlayerLive}
    end
  end
end
