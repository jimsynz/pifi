defmodule MyHiFiWeb.SettingsLiveTest do
  use MyHiFiWeb.ConnCase, async: false
  use Oban.Testing, repo: MyHiFi.Repo

  alias MyHiFi.Podcast.Index
  alias MyHiFi.Radio
  alias MyHiFi.Radio.Station.SyncFromRemote
  alias MyHiFi.Settings
  alias MyHiFi.Test.NoCardOutput

  defp station(overrides) do
    defaults = %{
      remote_id: "remote-#{System.unique_integer([:positive])}",
      title: "Station #{System.unique_integer([:positive])}",
      stream_url: "http://example.test/stream.mp3",
      codec: "MP3",
      bitrate: 128,
      hls?: false,
      country_code: "NZ",
      tags: ["news"],
      click_count: 0
    }

    Radio.upsert_station_from_remote!(Map.merge(defaults, overrides))
  end

  setup do
    Application.put_env(:my_hi_fi, Index, plug: {Req.Test, Index}, retry: false)
    on_exit(fn -> Application.delete_env(:my_hi_fi, Index) end)

    on_exit(fn ->
      # The settings outlive a test, because they are rows and not process state.
      for key <- [
            SyncFromRemote.countries_key(),
            MyHiFi.Player.output_device_key(),
            Index.key_setting(),
            Index.secret_setting()
          ] do
        case Settings.fetch(key) do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end
    end)

    :ok
  end

  describe "mount" do
    test "shows each part of the page", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings")

      assert html =~ "Settings"
      assert has_element?(view, "#output")
      assert has_element?(view, "#countries")
      assert has_element?(view, "#network")
      assert has_element?(view, "#storage")
    end

    test "reports the storage of the partition that holds the database", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#free-space")
      assert has_element?(view, "#database-size")
      assert render(view) =~ MyHiFi.Device.storage!().path
    end

    test "says that the network state comes from the device", %{conn: conn} do
      # `vintage_net` is a target dependency, so a host reports no interface.
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#no-network")
    end

    test "says when no sound card is present", %{conn: conn} do
      NoCardOutput.use_it()

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#no-output")
    end

    test "shows the default country when a person has chosen none", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ SyncFromRemote.default_countries()
    end

    test "counts the stations", %{conn: conn} do
      station(%{})
      station(%{})

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "holds 2 stations"
    end
  end

  describe "the interval" do
    test "reads the reports again, and it leaves the form alone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      station(%{})

      # A person may be in the middle of typing when the interval comes round.
      render_change(view, "save_countries", %{"countries" => %{"codes" => "nz"}})
      send(view.pid, :refresh)

      html = render(view)

      assert html =~ "holds 1 station."
      assert html =~ "NZ"
    end
  end

  describe "the country list" do
    test "a change stays, and the sync job reads it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#countries-form", countries: %{codes: "nz, au"})
        |> render_submit()

      assert html =~ "NZ, AU"
      assert SyncFromRemote.configured_countries() == ["NZ", "AU"]
    end

    test "the change is still there for the next visit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> form("#countries-form", countries: %{codes: "gb"}) |> render_submit()

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "GB"
    end

    test "it names the same country once only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> form("#countries-form", countries: %{codes: "nz, NZ , nz"}) |> render_submit()

      assert SyncFromRemote.configured_countries() == ["NZ"]
    end

    test "an empty list gives an error, and the old list stays", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> form("#countries-form", countries: %{codes: "nz"}) |> render_submit()

      html = view |> form("#countries-form", countries: %{codes: " , "}) |> render_submit()

      assert html =~ "Name at least one country"
      assert SyncFromRemote.configured_countries() == ["NZ"]
    end
  end

  describe "the output device" do
    test "the player keeps the choice, and it gives it back", _context do
      # The name of a card that no machine holds is enough here: the player keeps
      # what a person chose, and that is the part that a device needs.
      assert :ok = MyHiFi.Player.select_output("Audio")
      assert %{selected: "Audio"} = MyHiFi.Player.output()
    end

    test "the choice is still there after the player restarts", _context do
      assert :ok = MyHiFi.Player.select_output("Audio")

      # The setting is a row, so it outlives the process that read it.
      assert {:ok, %{value: "Audio"}} = Settings.fetch(MyHiFi.Player.output_device_key())
    end
  end

  describe "asking for the stations" do
    test "puts a job in the queue", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = view |> element("#sync") |> render_click()

      assert html =~ "asks for the station list"
      assert_enqueued(worker: MyHiFi.Radio.Station.Workers.SyncFromRemote)
    end
  end

  describe "the key of the Podcast Index" do
    defp accept_key do
      Req.Test.stub(Index, fn conn -> Req.Test.json(conn, %{"feeds" => []}) end)
    end

    defp refuse_key do
      Req.Test.stub(Index, fn conn ->
        Req.Test.json(Plug.Conn.put_status(conn, 401), %{"status" => "false"})
      end)
    end

    defp put_key do
      {:ok, _setting} = Settings.put(Index.key_setting(), "THEKEY")
      {:ok, _setting} = Settings.put(Index.secret_setting(), "THESECRET")
      :ok
    end

    test "a device with no key shows the address of the signup page", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings")

      assert html =~ "api.podcastindex.org/signup"
      refute has_element?(view, "#index-present")
      refute has_element?(view, "#remove-index-key")
    end

    test "a key that the index accepts stays, and the page says so", %{conn: conn} do
      accept_key()
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#index-form", index: %{key: "THEKEY", secret: "THESECRET"})
        |> render_submit()

      assert html =~ "The key works"
      assert Index.configured?()
      assert has_element?(view, "#index-present")
      assert has_element?(view, "#remove-index-key")
    end

    test "a key that the index refuses says which values to check", %{conn: conn} do
      refuse_key()
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#index-form", index: %{key: "WRONG", secret: "ALSOWRONG"})
        |> render_submit()

      assert html =~ "refused that key"
      # It stays, so a person can correct one of the two values.
      assert Index.configured?()
    end

    test "one value alone is not a key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#index-form", index: %{key: "THEKEY", secret: "  "})
        |> render_submit()

      assert html =~ "Give both the key and the secret"
      refute Index.configured?()
    end

    test "the page never sends the secret to a browser", %{conn: conn} do
      put_key()

      {:ok, _view, html} = live(conn, ~p"/settings")

      refute html =~ "THESECRET"
      refute html =~ "THEKEY"
      assert html =~ "The device holds a key"
    end

    test "the fields are empty after a save, so the secret goes nowhere", %{conn: conn} do
      accept_key()
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#index-form", index: %{key: "THEKEY", secret: "THESECRET"})
        |> render_submit()

      refute html =~ "THESECRET"
    end

    test "a person removes the key, and the subscriptions stay", %{conn: conn} do
      put_key()
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = view |> element("#remove-index-key") |> render_click()

      assert html =~ "holds no key"
      refute Index.configured?()
      refute has_element?(view, "#index-present")
    end

    test "an index that does not answer does not blame the key", %{conn: conn} do
      Req.Test.stub(Index, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#index-form", index: %{key: "THEKEY", secret: "THESECRET"})
        |> render_submit()

      assert html =~ "The key is stored"
      # A person must not read a fault of the network as a wrong key. `refused`
      # alone is no good here, because `econnrefused` holds it.
      refute html =~ "refused that key"
      assert Index.configured?()
    end
  end
end
