defmodule MyHiFiWeb.SettingsLiveTest do
  use MyHiFiWeb.ConnCase, async: false
  use Oban.Testing, repo: MyHiFi.Repo

  alias MyHiFi.Event
  alias MyHiFi.Event.Device, as: Events
  alias MyHiFi.Peripheral
  alias MyHiFi.Podcast.Index
  alias MyHiFi.Radio.Sync.FromRemote
  alias MyHiFi.Settings
  alias MyHiFi.Source
  alias MyHiFi.Test.Lamp
  alias MyHiFi.Test.NoCardOutput
  alias MyHiFi.Test.Stations
  alias MyHiFi.Test.TwoCardOutput

  @radio Source.slug(Source.InternetRadio)
  @podcasts Source.slug(Source.Podcasts)

  defp station(overrides), do: Stations.create(overrides)

  setup do
    Application.put_env(:my_hi_fi, Index, plug: {Req.Test, Index}, retry: false)
    on_exit(fn -> Application.delete_env(:my_hi_fi, Index) end)

    # `MyHiFi.AutoStandby` holds the period in its own state as well as in a row, so a
    # test that changed it must put the process back where it was.
    on_exit(fn -> MyHiFi.Playback.set_standby_minutes(20) end)

    on_exit(fn ->
      # The settings outlive a test, because they are rows and not process state.
      for key <- [
            MyHiFi.AutoStandby.key(),
            FromRemote.countries_key(),
            MyHiFi.Player.output_device_key(),
            Index.key_setting(),
            Index.secret_setting(),
            Peripheral.enabled_key(Lamp),
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
      assert has_element?(view, "#peripherals-row")
      assert has_element?(view, "#standby-row")
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

  describe "the peripheral list" do
    setup do
      Application.put_env(:my_hi_fi, :peripherals, [{Lamp, report_to: self()}])

      on_exit(fn ->
        Peripheral.stop(Lamp)
        Application.delete_env(:my_hi_fi, :peripherals)
      end)

      :ok
    end

    test "a firmware that knows no peripheral says so", %{conn: conn} do
      Application.delete_env(:my_hi_fi, :peripherals)

      {:ok, view, _html} = live(conn, ~p"/settings/peripherals")

      assert has_element?(view, "#no-peripherals")
    end

    test "each peripheral is out of use until a person says otherwise", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/peripherals")

      assert has_element?(view, "#peripheral-row-lamp")
      assert html =~ "Out of use"
    end

    test "a person puts one in use, and it starts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/peripherals")

      html = view |> element("#enable-peripheral-lamp") |> render_click()

      assert html =~ "Lamp is in use."
      assert Peripheral.running?(Lamp)
    end

    test "a person takes one out of use, and it stops", %{conn: conn} do
      :ok = Peripheral.enable(Lamp, true)

      {:ok, view, _html} = live(conn, ~p"/settings/peripherals")
      html = view |> element("#enable-peripheral-lamp") |> render_click()

      assert html =~ "Lamp is out of use."
      assert_receive {:lamp_terminated, :shutdown}
      refute Peripheral.running?(Lamp)
    end

    test "hardware that does not answer says why", %{conn: conn} do
      Application.put_env(:my_hi_fi, :peripherals, [{Lamp, fault: :no_such_device}])

      {:ok, view, _html} = live(conn, ~p"/settings/peripherals")
      html = view |> element("#enable-peripheral-lamp") |> render_click()

      assert html =~ "That did not start: :no_such_device"
      assert html =~ "In use, and it did not start"
    end

    test "the menu says how many run", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "0 of 1 running"

      :ok = Peripheral.enable(Lamp, true)

      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "1 of 1 running"
    end

    test "the choice is still there for the next visit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/peripherals")
      view |> element("#enable-peripheral-lamp") |> render_click()

      {:ok, _view, html} = live(conn, ~p"/settings/peripherals")

      assert html =~ "In use"
    end
  end

  describe "the standby section" do
    test "marks the period that the device holds", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/standby")

      assert html =~ "After 20 minutes"
      assert has_element?(view, "#standby-period-0")
      assert has_element?(view, "#standby-period-120")
    end

    test "a press of a period writes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/standby")

      html = view |> element("#standby-period-45") |> render_click()

      assert html =~ "The device enters standby after 45 minutes of quiet."
      assert MyHiFi.Playback.standby_minutes!() == 45
    end

    test "a person can keep the device awake", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/standby")

      html = view |> element("#standby-period-0") |> render_click()

      assert html =~ "The device stays awake."
      assert MyHiFi.Playback.standby_minutes!() == 0
    end

    test "the menu row says what the device holds", %{conn: conn} do
      {:ok, :ok} = MyHiFi.Playback.set_standby_minutes(0)

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "The device stays awake"
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

  # The page asks for no report on an interval. `MyHiFi.Device.Monitor` owns the three
  # sources of truth and publishes on the `:device` topic.
  describe "the reports that arrive" do
    test "a card that goes reaches the page", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings")

      refute html =~ "No sound card is present"

      Event.publish(:device, %Events.OutputChanged{devices: [], selected: nil, in_use: nil})

      assert render(view) =~ "No sound card is present"
    end

    test "free space that moves reaches the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/storage")

      Event.publish(:device, %Events.StorageChanged{
        path: "/root",
        total_bytes: 1_000_000_000,
        free_bytes: 4_000_000,
        used_bytes: 996_000_000,
        database_bytes: 2_000_000,
        full?: true
      })

      html = render(view)

      assert html =~ "/root"
      assert has_element?(view, "#storage-warning")
    end

    # `os_mon` holds the alarm, and a partition with room raises none.
    test "a partition with room draws no warning", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/storage")

      refute has_element?(view, "#storage-warning")
    end

    test "an interface that connects reaches the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/network")

      Event.publish(:device, %Events.NetworkChanged{
        interfaces: [
          %{
            name: "wlan0",
            type: "WiFi",
            connection: :internet,
            addresses: ["192.168.1.50"],
            ssid: "A network",
            signal_percent: 74
          }
        ]
      })

      assert render(view) =~ "192.168.1.50"
    end

    # A person may be in the middle of typing in the form of a source, and a report
    # touches nothing of that page.
    test "it leaves a source page alone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@radio}")

      Event.publish(:device, %Events.OutputChanged{devices: [], selected: nil, in_use: nil})

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

      assert html =~ FromRemote.default_countries()
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
      assert FromRemote.configured_countries() == ["NZ", "AU"]
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

      assert FromRemote.configured_countries() == ["NZ"]
    end

    test "an empty list gives an error, and the old list stays", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@radio}")
      view |> form("#source-form", source: %{countries: "nz"}) |> render_submit()

      html = view |> form("#source-form", source: %{countries: " , "}) |> render_submit()

      assert html =~ "Name at least one country"
      assert FromRemote.configured_countries() == ["NZ"]
    end

    test "asking for the stations puts a job in the queue", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@radio}")

      html = view |> element("#source-action-sync") |> render_click()

      assert html =~ "asks for the station list"
      assert_enqueued(worker: MyHiFi.Radio.Sync.Workers.FromRemote)
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

  # A DAC on the I2S pins answers to nothing until the bootloader loads an overlay for
  # it, so it reaches no list of cards. A person names what they added instead.
  describe "the audio hardware" do
    test "the output page holds a way to reach it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/output")

      assert has_element?(view, "#hardware-link")
    end

    test "it names each profile that this firmware knows", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/output/hardware")

      for profile <- MyHiFi.Hardware.profiles() do
        assert html =~ profile.title
      end
    end

    test "the profile in use is marked, and a person cannot choose it again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/output/hardware")

      assert view |> element("#profile-none") |> render() =~ "disabled"
    end

    # A host writes no boot configuration and restarts nothing, so the choice alone is
    # what this can read.
    test "a choice is kept", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/output/hardware")

      view |> element("#profile-hifiberry-dac") |> render_click()

      assert MyHiFi.Hardware.chosen().id == "hifiberry-dac"
      assert view |> element("#profile-hifiberry-dac") |> render() =~ "disabled"

      on_exit(fn ->
        case MyHiFi.Settings.fetch(MyHiFi.Hardware.setting()) do
          {:ok, setting} -> MyHiFi.Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end)
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

    test "a device with no key holds no control to read the index", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@podcasts}")

      refute has_element?(view, "#source-action-read_index")
    end

    # The read reaches a service, so it goes to a job and a person waits for nothing.
    test "a person reads the index again, and a job does it", %{conn: conn} do
      put_key()
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@podcasts}")

      html = view |> element("#source-action-read_index") |> render_click()

      assert html =~ "reads the index now"

      assert_enqueued(worker: MyHiFi.Podcast.Show.Workers.ReadTrending)
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
