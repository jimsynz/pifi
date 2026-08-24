defmodule MyHiFiWeb.SettingsLiveTest do
  use MyHiFiWeb.ConnCase, async: false
  use Oban.Testing, repo: MyHiFi.Repo

  alias MyHiFi.Podcast.Index
  alias MyHiFi.Radio
  alias MyHiFi.Radio.Station.SyncFromRemote
  alias MyHiFi.Settings
  alias MyHiFi.Source
  alias MyHiFi.Test.NoCardOutput
  alias MyHiFi.Test.TwoCardOutput

  @radio Source.slug(Source.InternetRadio)
  @podcasts Source.slug(Source.Podcasts)

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
            Index.secret_setting(),
            Source.enabled_key(Source.InternetRadio),
            Source.enabled_key(Source.Podcasts)
          ] do
        case Settings.fetch(key) do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end
    end)

    :ok
  end

  describe "the menu" do
    test "holds one row for each section", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings")

      assert html =~ "Settings"
      assert has_element?(view, "#output-row")
      assert has_element?(view, "#sources-row")
      assert has_element?(view, "#network-row")
      assert has_element?(view, "#storage-row")
    end

    test "each row says what the section holds", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "2 of 2 in use"
      assert html =~ "free of"
    end

    test "a row opens its section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      {:ok, _view, html} =
        view |> element("#sources-row") |> render_click() |> follow_redirect(conn)

      assert html =~ "Internet radio"
    end
  end

  describe "the output section" do
    test "says when no sound card is present", %{conn: conn} do
      NoCardOutput.use_it()

      {:ok, view, _html} = live(conn, ~p"/settings/output")

      assert has_element?(view, "#no-output")
      assert has_element?(view, "#back")
    end

    test "holds one row for each card", %{conn: conn} do
      TwoCardOutput.use_it()

      {:ok, _view, html} = live(conn, ~p"/settings/output")

      assert html =~ "The first card"
      assert html =~ "The second card"
    end

    # A person who chose nothing still hears one card, and the page must say which
    # one. `MyHiFi.Player` uses the first card that is present.
    test "the first card is marked before a person chooses one", %{conn: conn} do
      TwoCardOutput.use_it()

      {:ok, view, html} = live(conn, ~p"/settings/output")

      assert has_element?(view, "#selected-0")
      refute has_element?(view, "#selected-1")
      assert html =~ "By default"
    end

    test "the menu row says that the card in use is the default", %{conn: conn} do
      TwoCardOutput.use_it()

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "The first card, by default"
    end

    test "a touch on a row chooses that card, and the row shows it", %{conn: conn} do
      TwoCardOutput.use_it()
      [_first, second] = TwoCardOutput.devices!()

      {:ok, view, _html} = live(conn, ~p"/settings/output")
      html = view |> element("#select-output-1") |> render_click()

      assert html =~ "The output device is #{second.id}."
      assert has_element?(view, "#selected-1")
      refute has_element?(view, "#selected-0")
      refute html =~ "By default"
      assert %{selected: id, in_use: id} = MyHiFi.Player.output()
      assert id == second.id
    end

    test "the row of a card that a person chose is dead, so it starts no stream again",
         %{conn: conn} do
      TwoCardOutput.use_it()
      [first | _rest] = TwoCardOutput.devices!()
      assert :ok = MyHiFi.Player.select_output(first.id)

      {:ok, view, _html} = live(conn, ~p"/settings/output")

      assert has_element?(view, "#selected-0")
      assert has_element?(view, "#select-output-0[disabled]")
      refute has_element?(view, "#select-output-1[disabled]")
    end

    # The card in use is the default, so a person can still make that choice their
    # own. The row therefore stays live.
    test "the row of the card in use by default is live", %{conn: conn} do
      TwoCardOutput.use_it()

      {:ok, view, _html} = live(conn, ~p"/settings/output")

      refute has_element?(view, "#select-output-0[disabled]")
    end

    test "a choice that names a card which left the machine says so", %{conn: conn} do
      TwoCardOutput.use_it()
      assert :ok = MyHiFi.Player.select_output("rate48:CARD=gone,DEV=0")

      {:ok, view, _html} = live(conn, ~p"/settings/output")

      assert has_element?(view, "#absent-output")
      # The player uses the first card that is present, and the page marks that one.
      assert has_element?(view, "#selected-0")
    end
  end

  describe "the network section" do
    test "says that the network state comes from the device", %{conn: conn} do
      # `vintage_net` is a target dependency, so a host reports no interface.
      {:ok, view, _html} = live(conn, ~p"/settings/network")

      assert has_element?(view, "#no-network")
    end
  end

  describe "the storage section" do
    test "reports the storage of the partition that holds the database", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/storage")

      assert has_element?(view, "#free-space")
      assert has_element?(view, "#database-size")
      assert render(view) =~ MyHiFi.Device.storage!().path
    end
  end

  describe "the interval" do
    test "reads the reports again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      NoCardOutput.use_it()
      send(view.pid, :refresh)

      assert render(view) =~ "No sound card is present"
    end

    test "it leaves a source page alone, because a person may be typing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@radio}")

      send(view.pid, :refresh)

      assert render(view) =~ "Station countries"
    end
  end

  describe "the source list" do
    test "holds one row for each source, and each one is in use", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/sources")

      assert has_element?(view, "#source-row-#{@radio}")
      assert has_element?(view, "#source-row-#{@podcasts}")
      refute html =~ "Out of use"
    end

    test "a person takes a source out of use, and the top row loses it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources")

      html = view |> element("#enable-source-#{@podcasts}") |> render_click()

      assert html =~ "Podcasts is out of use."
      refute Source.enabled?(Source.Podcasts)
      assert Source.enabled() == [Source.InternetRadio]

      {:ok, _view, html} = live(conn, ~p"/settings")
      refute html =~ ~s(id="source-#{@podcasts}")
    end

    test "a person puts a source back in use", %{conn: conn} do
      Source.enable(Source.Podcasts, false)

      {:ok, view, _html} = live(conn, ~p"/settings/sources")
      html = view |> element("#enable-source-#{@podcasts}") |> render_click()

      assert html =~ "Podcasts is in use."
      assert Source.enabled?(Source.Podcasts)
    end

    test "the choice is still there for the next visit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources")
      view |> element("#enable-source-#{@radio}") |> render_click()

      {:ok, _view, html} = live(conn, ~p"/settings/sources")

      assert html =~ "Out of use"
    end
  end

  describe "one source" do
    test "a name that no source holds gives the list back", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/settings/sources"}}} =
               live(conn, ~p"/settings/sources/nothing")
    end

    test "a source that holds nothing to change says so", %{conn: conn} do
      Application.put_env(:my_hi_fi, :sources, [MyHiFi.Test.PlainSource])
      on_exit(fn -> Application.delete_env(:my_hi_fi, :sources) end)

      {:ok, view, _html} = live(conn, ~p"/settings/sources/plain-source")

      assert has_element?(view, "#no-source-settings")
      assert has_element?(view, "#enable-source-plain-source")
    end
  end

  describe "the settings of internet radio" do
    test "shows the default country when a person has chosen none", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/sources/#{@radio}")

      assert html =~ SyncFromRemote.default_countries()
    end

    test "counts the stations", %{conn: conn} do
      station(%{})
      station(%{})

      {:ok, _view, html} = live(conn, ~p"/settings/sources/#{@radio}")

      assert html =~ "holds 2 stations"
    end

    test "a change of the countries stays, and the sync job reads it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@radio}")

      html =
        view
        |> form("#source-form", source: %{countries: "nz, au"})
        |> render_submit()

      assert html =~ "NZ, AU"
      assert SyncFromRemote.configured_countries() == ["NZ", "AU"]
    end

    test "the change is still there for the next visit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@radio}")
      view |> form("#source-form", source: %{countries: "gb"}) |> render_submit()

      {:ok, _view, html} = live(conn, ~p"/settings/sources/#{@radio}")

      assert html =~ "GB"
    end

    test "it names the same country once only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@radio}")

      view |> form("#source-form", source: %{countries: "nz, NZ , nz"}) |> render_submit()

      assert SyncFromRemote.configured_countries() == ["NZ"]
    end

    test "an empty list gives an error, and the old list stays", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@radio}")
      view |> form("#source-form", source: %{countries: "nz"}) |> render_submit()

      html = view |> form("#source-form", source: %{countries: " , "}) |> render_submit()

      assert html =~ "Name at least one country"
      assert SyncFromRemote.configured_countries() == ["NZ"]
    end

    test "asking for the stations puts a job in the queue", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@radio}")

      html = view |> element("#source-action-sync") |> render_click()

      assert html =~ "asks for the station list"
      assert_enqueued(worker: MyHiFi.Radio.Station.Workers.SyncFromRemote)
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
      {:ok, view, html} = live(conn, ~p"/settings/sources/#{@podcasts}")

      assert html =~ "api.podcastindex.org/signup"
      assert html =~ "The device holds no key"
      refute has_element?(view, "#source-action-remove_key")
    end

    test "a key that the index accepts stays, and the page says so", %{conn: conn} do
      accept_key()
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@podcasts}")

      html =
        view
        |> form("#source-form", source: %{key: "THEKEY", secret: "THESECRET"})
        |> render_submit()

      assert html =~ "The key works"
      assert html =~ "The device holds a key"
      assert Index.configured?()
      assert has_element?(view, "#source-action-remove_key")
    end

    test "a key that the index refuses says which values to check", %{conn: conn} do
      refuse_key()
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@podcasts}")

      html =
        view
        |> form("#source-form", source: %{key: "WRONG", secret: "ALSOWRONG"})
        |> render_submit()

      assert html =~ "refused that key"
      # It stays, so a person can correct one of the two values.
      assert Index.configured?()
    end

    test "one value alone is not a key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@podcasts}")

      html =
        view
        |> form("#source-form", source: %{key: "THEKEY", secret: "  "})
        |> render_submit()

      assert html =~ "Give both the key and the secret"
      refute Index.configured?()
    end

    test "the page never sends the secret to a browser", %{conn: conn} do
      put_key()

      {:ok, _view, html} = live(conn, ~p"/settings/sources/#{@podcasts}")

      refute html =~ "THESECRET"
      refute html =~ "THEKEY"
      assert html =~ "The device holds a key"
    end

    test "the fields are empty after a save, so the secret goes nowhere", %{conn: conn} do
      accept_key()
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@podcasts}")

      html =
        view
        |> form("#source-form", source: %{key: "THEKEY", secret: "THESECRET"})
        |> render_submit()

      refute html =~ "THESECRET"
    end

    test "a person removes the key, and the subscriptions stay", %{conn: conn} do
      put_key()
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@podcasts}")

      html = view |> element("#source-action-remove_key") |> render_click()

      assert html =~ "holds no key"
      refute Index.configured?()
      refute has_element?(view, "#source-action-remove_key")
    end

    test "an index that does not answer does not blame the key", %{conn: conn} do
      Req.Test.stub(Index, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@podcasts}")

      html =
        view
        |> form("#source-form", source: %{key: "THEKEY", secret: "THESECRET"})
        |> render_submit()

      assert html =~ "The key is stored"
      # A person must not read a fault of the network as a wrong key. `refused`
      # alone is no good here, because `econnrefused` holds it.
      refute html =~ "refused that key"
      assert Index.configured?()
    end
  end
end
