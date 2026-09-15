defmodule MyHiFiWeb.ShellTest do
  # The pages read `MyHiFi.Player`, which one process holds for the whole node.
  use MyHiFiWeb.ConnCase, async: false

  alias MyHiFi.Artwork
  alias MyHiFi.Artwork.Thumbnail
  alias MyHiFi.Cache
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

  # A list draws the address of a picture that the cache may not hold, and the browser
  # keeps the 404 that it gets. `assets/js/cover.js` asks for the address again on this
  # event, so a picture that arrives a moment later needs no reload.
  describe "a picture that arrives while a page is open" do
    test "a thumbnail that arrives reaches the browser", %{conn: conn} do
      {:ok, view, _html} = live(conn, @radio)

      stub_artwork()
      {:ok, name} = Artwork.fetch("https://station.test/logo.jpg")
      {:ok, entry} = Cache.fetch("artwork", name)

      Cache.put!("artwork", "#{name}.thumbnail", %{
        bytes: "a small picture",
        content_type: "image/jpeg",
        variant_of_blob_id: entry.id,
        variant_name: "thumbnail",
        variant_digest: Thumbnail.digest()
      })

      assert_push_event(view, "artwork-ready", %{path: "/artwork/" <> _rest = path})
      assert path == "/artwork/#{name}/thumbnail"
    end

    # The picture itself carries no address that a page drew, and an event for it would
    # make every browser ask for a thumbnail that the device has not written yet.
    test "the picture itself reaches no browser", %{conn: conn} do
      {:ok, view, _html} = live(conn, @radio)

      stub_artwork()
      {:ok, _name} = Artwork.fetch("https://station.test/logo.jpg")

      refute_push_event(view, "artwork-ready", %{}, 100)
    end
  end

  defp stub_artwork do
    Application.put_env(:my_hi_fi, Artwork, plug: {Req.Test, Artwork}, retry: false)
    on_exit(fn -> Application.delete_env(:my_hi_fi, Artwork) end)

    Req.Test.stub(Artwork, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, <<0xFF, 0xD8, 0xFF, "the rest of a small image">>)
    end)
  end
end
