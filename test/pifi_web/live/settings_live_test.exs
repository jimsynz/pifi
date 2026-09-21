defmodule PiFiWeb.SettingsLiveTest do
  use PiFiWeb.ConnCase, async: false
  use Oban.Testing, repo: PiFi.Repo

  alias Nerves.Runtime.KV
  alias PiFi.Artwork
  alias PiFi.Device.Identity
  alias PiFi.Device.Timezone
  alias PiFi.Device.Upgrade
  alias PiFi.Device.Upgrade.Forge
  alias PiFi.Device.Upgrade.Server, as: UpgradeServer
  alias PiFi.Event
  alias PiFi.Event.Device, as: Events
  alias PiFi.HomeAssistant
  alias PiFi.Output.Volume
  alias PiFi.Peripheral
  alias PiFi.Player.Crossfade
  alias PiFi.Podcast.Index
  alias PiFi.Radio.Sync.FromRemote
  alias PiFi.Settings
  alias PiFi.Source
  alias PiFi.Spotify
  alias PiFi.Test.Lamp
  alias PiFi.Test.NoCardOutput
  alias PiFi.Test.Panel
  alias PiFi.Test.Stations
  alias PiFi.Test.TwoCardOutput

  # One flat picture of 2 by 2 pixels, and a whole one. `PiFi.Artwork.put/1` runs
  # `vipsthumbnail` over the bytes, and a header alone does not answer that.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGM4IacBRAwQCgAgFgQ5YebC6gAAAABJRU5ErkJggg=="
       )

  @radio Source.slug(Source.InternetRadio)
  @podcasts Source.slug(Source.Podcasts)

  defp station(overrides), do: Stations.create(overrides)

  setup do
    Application.put_env(:pifi, Index, plug: {Req.Test, Index}, retry: false)
    on_exit(fn -> Application.delete_env(:pifi, Index) end)

    # The standby section reads and writes the period through `PiFi.Playback`, which
    # names the process for the whole node. `PiFi.Application` starts none in the test
    # environment, so this test holds its own and it goes at the end of the test.
    start_supervised!(PiFi.AutoStandby)

    # The screen section reads and writes its period through `PiFi.DeviceUi`, which the
    # test environment starts no instance of either.
    start_supervised!(PiFi.DeviceUi)

    on_exit(fn ->
      # The name lives in `Nerves.Runtime.KV`, and a host build keeps that store in
      # memory for the whole node. See `PiFi.Device.Identity`.
      KV.put("pifi_device_name", "")
      Identity.remove_splash()
      File.rm_rf(Artwork.directory())

      # The settings outlive a test, because they are rows and not process state.
      for key <- [
            PiFi.AutoStandby.key(),
            PiFi.DeviceUi.blank_key(),
            FromRemote.countries_key(),
            PiFi.Player.output_device_key(),
            Index.key_setting(),
            Index.secret_setting(),
            Peripheral.enabled_key(Lamp),
            Peripheral.enabled_key(Panel),
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
      assert has_element?(view, "#device-row")
      assert has_element?(view, "#output-row")
      assert has_element?(view, "#sources-row")
      assert has_element?(view, "#peripherals-row")
      assert has_element?(view, "#standby-row")
      assert has_element?(view, "#network-row")
      assert has_element?(view, "#storage-row")
    end

    test "each row says what the section holds", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "1 of 4 enabled"
      assert html =~ "free of"
    end

    test "a row opens its section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      {:ok, _view, html} =
        view |> element("#sources-row") |> render_click() |> follow_redirect(conn)

      assert html =~ "Internet radio"
    end
  end

  describe "the device section" do
    test "it draws the name and the address of the device", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/device")

      assert html =~ "PiFi"
      assert html =~ "pifi.local"
      assert has_element?(view, "#device-form")
      assert has_element?(view, "#splash-form")
      assert has_element?(view, "#no-splash")
    end

    test "a person names the device", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/device")

      html =
        view
        |> form("#device-form", device: %{name: "Kitchen"})
        |> render_submit()

      assert html =~ "Renamed to Kitchen."
      assert html =~ "kitchen.local"
      assert Identity.name() == "Kitchen"
    end

    test "a name that no person can read is refused, and the device keeps its own",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/device")

      html =
        view
        |> form("#device-form", device: %{name: "   "})
        |> render_submit()

      assert html =~ "A device needs a name."
      assert Identity.name() == "PiFi"
    end

    test "a person gives the picture of the idle screen, and takes it away again",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/device")

      picture =
        file_input(view, "#splash-form", :splash, [
          %{name: "splash.png", content: @png, type: "image/png"}
        ])

      # The upload holds itself when the last byte lands, so no person presses
      # anything. A control for that raised `cannot consume uploaded files when entries
      # are still in progress` on a device, because a board reads 4 MB over Wi-Fi in
      # more time than a person waits.
      html = render_upload(picture, "splash.png")

      assert html =~ "Each screen shows that picture now."
      assert has_element?(view, "#splash")
      assert Identity.splash_path() != nil

      html = view |> element("#remove-splash") |> render_click()

      assert html =~ "Each screen shows the default picture again."
      assert has_element?(view, "#no-splash")
      assert Identity.splash_path() == nil
    end

    # This is the failure that a control gave: a press while the bytes were still
    # arriving raised `cannot consume uploaded files when entries are still in
    # progress`, and the LiveView went with it.
    test "a picture that is still arriving is held by nothing yet", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/device")

      picture =
        file_input(view, "#splash-form", :splash, [
          %{name: "splash.png", content: @png, type: "image/png"}
        ])

      html = render_upload(picture, "splash.png", 50)

      refute html =~ "Each screen shows that picture now."
      assert Identity.splash_path() == nil

      assert render_upload(picture, "splash.png", 50) =~ "Each screen shows that picture now."
      assert Identity.splash_path() != nil
    end

    # The browser refuses a type that the upload does not name, so this reads the answer
    # of that check and not the one of `PiFi.Artwork`.
    test "a file that is not a JPEG and not a PNG is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/device")

      picture =
        file_input(view, "#splash-form", :splash, [
          %{name: "notes.txt", content: "words", type: "text/plain"}
        ])

      assert {:error, [[_ref, :not_accepted]]} = render_upload(picture, "notes.txt")
      assert render(view) =~ "a JPEG or a PNG"
    end

    # Two browsers hold this page, and one of them names the device.
    test "a name that another page wrote reaches this one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/device")

      Event.publish(:device, %Events.IdentityChanged{name: "Study", splash_path: nil})

      assert render(view) =~ "study.local"
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
    # one. `PiFi.Player` uses the first card that is present.
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

      assert html =~ "Now using #{second.id}."
      assert has_element?(view, "#selected-1")
      refute has_element?(view, "#selected-0")
      refute html =~ "By default"
      assert %{selected: id, in_use: id} = PiFi.Player.output()
      assert id == second.id
    end

    test "the row of a card that a person chose is dead, so it starts no stream again",
         %{conn: conn} do
      TwoCardOutput.use_it()
      [first | _rest] = TwoCardOutput.devices!()
      assert :ok = PiFi.Player.select_output(first.id)

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
      assert :ok = PiFi.Player.select_output("rate48:CARD=gone,DEV=0")

      {:ok, view, _html} = live(conn, ~p"/settings/output")

      assert has_element?(view, "#absent-output")
      # The player uses the first card that is present, and the page marks that one.
      assert has_element?(view, "#selected-0")
    end
  end

  describe "the peripheral list" do
    setup do
      Application.put_env(:pifi, :peripherals, [{Lamp, report_to: self()}])

      on_exit(fn ->
        Peripheral.stop(Lamp)
        Application.delete_env(:pifi, :peripherals)
      end)

      :ok
    end

    test "a firmware that knows no peripheral says so", %{conn: conn} do
      Application.delete_env(:pifi, :peripherals)

      {:ok, view, _html} = live(conn, ~p"/settings/peripherals")

      assert has_element?(view, "#no-peripherals")
    end

    test "each peripheral is out of use until a person says otherwise", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/peripherals")

      assert has_element?(view, "#peripheral-row-lamp")
      assert html =~ "Disabled"
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
      Application.put_env(:pifi, :peripherals, [{Lamp, fault: :no_such_device}])

      {:ok, view, _html} = live(conn, ~p"/settings/peripherals")
      html = view |> element("#enable-peripheral-lamp") |> render_click()

      assert html =~ "start that: :no_such_device"
      assert html =~ "Enabled, but it failed to start"
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

      assert html =~ "Enabled"
    end
  end

  describe "the refresh periods of a source" do
    setup do
      on_exit(fn ->
        for %{key: key} <- PiFi.AutoSync.jobs() do
          case PiFi.Settings.fetch(PiFi.AutoSync.hours_key(key)) do
            {:ok, setting} -> PiFi.Settings.delete!(setting)
            {:error, _reason} -> :ok
          end
        end
      end)

      :ok
    end

    # A job of a source belongs beside the settings of that source, and not on a page of
    # its own. See `PiFi.AutoSync.jobs_for/1`.
    test "the section of a source draws the jobs of that source alone", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/sources/internet-radio")

      assert has_element?(view, "#sync-radio")
      assert html =~ "Internet radio stations"

      refute has_element?(view, "#sync-podcast-trending")
      refute has_element?(view, "#sync-podcast-refresh")
    end

    test "a source with more than one job draws each of them", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/podcasts")

      assert has_element?(view, "#sync-podcast-trending")
      assert has_element?(view, "#sync-podcast-refresh")
      refute has_element?(view, "#sync-radio")
    end

    test "a press of a period writes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/internet-radio")

      html = view |> element("#sync-radio-24") |> render_click()

      assert html =~ "Internet radio stations: daily."
      assert PiFi.AutoSync.hours("radio") == 24
    end

    test "a person can turn one job off and leave the others", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources/podcasts")

      html = view |> element("#sync-podcast-trending-0") |> render_click()

      assert html =~ "Trending podcasts does not sync by itself now."
      assert PiFi.AutoSync.hours("podcast-trending") == 0
      assert PiFi.AutoSync.hours("podcast-refresh") == 6
    end

    test "the menu holds no section of its own for this", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      refute has_element?(view, "#syncing-row")
    end
  end

  describe "preparing to be switched off" do
    setup do
      on_exit(fn ->
        case Settings.fetch(PiFi.SwitchOff.key()) do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end)

      :ok
    end

    # The device on a stereo wants its background work to go on while it stands in
    # standby, so a device that no person changed does not prepare.
    test "a device that no person changed does not prepare", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/standby")

      assert has_element?(view, "#toggle-switch-off[aria-pressed=false]")
      refute PiFi.SwitchOff.enabled?()
    end

    test "a person turns it on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/standby")

      html = view |> element("#toggle-switch-off") |> render_click()

      assert html =~ "safe to switch off"
      assert PiFi.SwitchOff.enabled?()
    end

    test "a person turns it off again", %{conn: conn} do
      :ok = PiFi.SwitchOff.enable(true)

      {:ok, view, _html} = live(conn, ~p"/settings/standby")
      html = view |> element("#toggle-switch-off") |> render_click()

      assert html =~ "keeps working in standby"
      refute PiFi.SwitchOff.enabled?()
    end
  end

  describe "the time zone section" do
    setup do
      on_exit(fn -> Timezone.put(Timezone.default()) end)

      :ok
    end

    test "a device that no person told says so, and says it reads UTC", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Not set, so times read in UTC"
    end

    test "a person names a place and the menu then says it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/timezone")

      html =
        view
        |> form("#timezone-form", %{"timezone" => "Pacific/Auckland"})
        |> render_submit()

      assert html =~ "PiFi is in Pacific/Auckland now."
      assert Timezone.get() == "Pacific/Auckland"

      {:ok, _menu, html} = live(conn, ~p"/settings")
      assert html =~ "Pacific/Auckland"
    end

    # An error says what happened and what a person can do, and it never makes them feel
    # stupid.
    test "a place that PiFi does not know is refused and nothing changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/timezone")

      html =
        view
        |> form("#timezone-form", %{"timezone" => "Middle/Earth"})
        |> render_submit()

      assert html =~ "doesn&#39;t know a place called Middle/Earth"
      assert Timezone.get() == "Etc/UTC"
    end

    test "the page shows the time where the person is", %{conn: conn} do
      :ok = Timezone.put("Pacific/Auckland")

      {:ok, view, _html} = live(conn, ~p"/settings/timezone")

      assert has_element?(view, "#timezone-now")
      assert render(view) =~ "Pacific/Auckland"
    end
  end

  describe "the crossfade section" do
    setup do
      on_exit(fn -> Crossfade.set_seconds(0) end)

      :ok
    end

    # A crossfade suits a playlist of songs and talks over the first word of a podcast,
    # so a device that no person changed plays one track at a time.
    test "a device that no person changed has it off", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/crossfade")

      assert html =~ "Off"
      assert has_element?(view, "#crossfade-length-0")
      assert has_element?(view, "#crossfade-length-3")
    end

    test "a press of a length writes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/crossfade")

      html = view |> element("#crossfade-length-5") |> render_click()

      assert html =~ "Tracks cross over for 5 seconds."
      assert PiFi.Playback.crossfade_seconds!() == 5
    end

    test "a person turns it off again", %{conn: conn} do
      :ok = Crossfade.set_seconds(5)

      {:ok, view, _html} = live(conn, ~p"/settings/crossfade")
      html = view |> element("#crossfade-length-0") |> render_click()

      assert html =~ "One track stops before the next one starts."
      assert PiFi.Playback.crossfade_seconds!() == 0
    end

    test "the menu says what it is set to", %{conn: conn} do
      :ok = Crossfade.set_seconds(2)

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "2 seconds"
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

      assert html =~ "PiFi enters standby after 45 minutes of quiet."
      assert PiFi.Playback.standby_minutes!() == 45
    end

    test "a person can keep the device awake", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/standby")

      html = view |> element("#standby-period-0") |> render_click()

      assert html =~ "PiFi stays awake."
      assert PiFi.Playback.standby_minutes!() == 0
    end

    test "the menu row says what the device holds", %{conn: conn} do
      {:ok, :ok} = PiFi.Playback.set_standby_minutes(0)

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Stays awake"
    end
  end

  # **The page of a screen is for a device that draws one.** See
  # `PiFi.Peripheral.any_screen?/0`.
  describe "the screen section" do
    setup do
      Application.put_env(:pifi, :peripherals, [{Panel, []}])
      Peripheral.enable(Panel, true)

      on_exit(fn ->
        Peripheral.stop(Panel)
        Application.delete_env(:pifi, :peripherals)
      end)

      :ok
    end

    test "it draws the periods", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/screen")

      assert html =~ "Never"
      assert has_element?(view, "#screen-period-0")
      assert has_element?(view, "#screen-period-30")
    end

    test "a press of a period writes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/screen")

      html = view |> element("#screen-period-30") |> render_click()

      assert html =~ "The screen goes dark after 30 seconds."
      assert PiFi.Playback.screen_blank_seconds!() == 30
    end

    test "a person can keep the screen lit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/screen")

      html = view |> element("#screen-period-0") |> render_click()

      assert html =~ "The screen stays lit."
      assert PiFi.Playback.screen_blank_seconds!() == 0
    end

    test "the menu row says what the device holds", %{conn: conn} do
      {:ok, :ok} = PiFi.Playback.set_screen_blank_seconds(30)

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "After 30 seconds"
    end

    # A person with a knob and a battery gauge and no panel has no use for this.
    test "a device with no screen draws no row for it", %{conn: conn} do
      Peripheral.enable(Panel, false)

      {:ok, view, _html} = live(conn, ~p"/settings")

      refute has_element?(view, "#screen-row")
    end

    test "a device with no screen sends a person back from the page", %{conn: conn} do
      Peripheral.enable(Panel, false)

      assert {:error, {:live_redirect, %{to: "/settings"}}} = live(conn, ~p"/settings/screen")
    end

    # A peripheral that this firmware knows is not a peripheral that a person wired.
    test "a screen that no person put in use draws no row either", %{conn: conn} do
      Application.put_env(:pifi, :peripherals, [{Panel, []}, {Lamp, []}])
      Peripheral.enable(Panel, false)
      Peripheral.enable(Lamp, true)

      on_exit(fn -> Peripheral.enable(Lamp, false) end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      refute has_element?(view, "#screen-row")
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
      assert render(view) =~ PiFi.Device.storage!().path
    end

    # A person who reads "3.6 GB used" learns nothing that they can act on, so the page
    # names the kinds. See `PiFi.Device.Storage.Usage`.
    test "it draws a bar of the kinds of media, and a row for each one", %{conn: conn} do
      PiFi.Cache.put!("artwork", "cover", %{bytes: String.duplicate("c", 700)})

      {:ok, view, _html} = live(conn, ~p"/settings/storage")

      assert has_element?(view, "#storage-usage")
      assert has_element?(view, "#usage-artwork", "Artwork")
      assert has_element?(view, "#usage-other", "Other")
    end

    # The colour says which kind, and the row says it in words as well, so a reader who
    # cannot tell two colours apart still reads the page.
    test "a kind that holds no byte draws no row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/storage")

      refute has_element?(view, "#usage-jellyfin")
    end
  end

  # **A person turns this on, and a card that holds no level cannot be turned on.**
  # See `PiFi.Output.Volume`.
  describe "the volume control" do
    setup do
      TwoCardOutput.use_it()
      :ok = PiFi.Player.select_output("rate48:CARD=first,DEV=0")
      start_supervised!(Volume)
      Volume.state()

      :ok
    end

    test "a card that holds a level offers the control", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/output")

      assert has_element?(view, "#toggle-volume")
      refute has_element?(view, "#no-volume-control")
    end

    test "a person turns it on, and the page says what changed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/output")

      html = view |> element("#toggle-volume") |> render_click()

      assert html =~ "PiFi sets the volume on the sound card"
      assert %{enabled?: true} = PiFi.Playback.volume!()
    end

    test "a person turns it off again", %{conn: conn} do
      :ok = Volume.enable(true)

      {:ok, view, _html} = live(conn, ~p"/settings/output")

      html = view |> element("#toggle-volume") |> render_click()

      assert html =~ "Use your amplifier instead"
      assert %{enabled?: false} = PiFi.Playback.volume!()
    end

    # **A DAC of a fixed output is normal.** A person with one reads why, rather than a
    # control that does nothing.
    test "a card that holds no level says so instead", %{conn: conn} do
      :ok = PiFi.Player.select_output("rate48:CARD=second,DEV=0")

      {:ok, view, _html} = live(conn, ~p"/settings/output")

      assert has_element?(view, "#no-volume-control")
      assert render(view) =~ "no volume control PiFi can set"
    end
  end

  # The page asks for no report on an interval. `PiFi.Device.Monitor` owns the three
  # sources of truth and publishes on the `:device` topic.
  describe "the reports that arrive" do
    test "a card that goes reaches the page", %{conn: conn} do
      TwoCardOutput.use_it()

      {:ok, view, html} = live(conn, ~p"/settings")

      refute html =~ "No sound card found"

      Event.publish(:device, %Events.OutputChanged{devices: [], selected: nil, in_use: nil})

      assert render(view) =~ "No sound card found"
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
    # A source that needs an address or a key is out of use until a person sets it up,
    # and the list is where they find it. See `PiFi.Source.enabled?/1`.
    test "holds one row for each source, and it says which are in use", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources")

      assert has_element?(view, "#source-row-#{@radio}", "Enabled")
      assert has_element?(view, "#source-row-#{@podcasts}", "Disabled")
    end

    test "a person takes a source out of use, and the top row loses it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/sources")

      html = view |> element("#enable-source-#{@radio}") |> render_click()

      assert html =~ "Internet radio is out of use."
      refute Source.enabled?(Source.InternetRadio)
      assert Source.enabled() == []

      {:ok, _view, html} = live(conn, ~p"/settings")
      refute html =~ ~s(id="source-#{@radio}")
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

      {:ok, view, _html} = live(conn, ~p"/settings/sources")

      assert has_element?(view, "#source-row-#{@radio}", "Disabled")
    end
  end

  describe "one source" do
    test "a name that no source holds gives the list back", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/settings/sources"}}} =
               live(conn, ~p"/settings/sources/nothing")
    end

    test "a source that holds nothing to change says so", %{conn: conn} do
      Application.put_env(:pifi, :sources, [PiFi.Test.PlainSource])
      on_exit(fn -> Application.delete_env(:pifi, :sources) end)

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

      assert html =~ "has 2 stations"
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
      assert_enqueued(worker: PiFi.Radio.Sync.Workers.FromRemote)
    end
  end

  describe "the output device" do
    test "the player keeps the choice, and it gives it back", _context do
      # The name of a card that no machine holds is enough here: the player keeps
      # what a person chose, and that is the part that a device needs.
      assert :ok = PiFi.Player.select_output("Audio")
      assert %{selected: "Audio"} = PiFi.Player.output()
    end

    test "the choice is still there after the player restarts", _context do
      assert :ok = PiFi.Player.select_output("Audio")

      # The setting is a row, so it outlives the process that read it.
      assert {:ok, %{value: "Audio"}} = Settings.fetch(PiFi.Player.output_device_key())
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

      for profile <- PiFi.Hardware.profiles() do
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

      assert PiFi.Hardware.chosen().id == "hifiberry-dac"
      assert view |> element("#profile-hifiberry-dac") |> render() =~ "disabled"

      on_exit(fn ->
        case PiFi.Settings.fetch(PiFi.Hardware.setting()) do
          {:ok, setting} -> PiFi.Settings.delete!(setting)
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
      assert html =~ "This device has no key"
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
      assert html =~ "This device has a key"
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
      assert html =~ "This device has a key"
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

      assert_enqueued(worker: PiFi.Podcast.Show.Workers.ReadTrending)
    end

    test "a person removes the key, and the subscriptions stay", %{conn: conn} do
      put_key()
      {:ok, view, _html} = live(conn, ~p"/settings/sources/#{@podcasts}")

      html = view |> element("#source-action-remove_key") |> render_click()

      assert html =~ "has no key now"
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

  describe "the firmware section" do
    test "it names the version that runs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/firmware")

      assert has_element?(view, "#running-version", Upgrade.running_version())
      assert has_element?(view, "#up-to-date")
      refute has_element?(view, "#install-upgrade")
    end

    # A version that lands while a person has the page open must reach them, in the way
    # that the storage and the network do.
    test "a version that the forge names reaches the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/firmware")

      Event.publish(:device, %Events.UpgradeChanged{
        running: "0.1.0",
        available: "9.9.9",
        notes: "What changed.",
        checked_at: DateTime.utc_now(),
        state: :idle,
        percent: 0
      })

      html = render(view)

      assert html =~ "Version 9.9.9 is ready."
      assert html =~ "What changed."
      assert has_element?(view, "#install-upgrade")
      refute has_element?(view, "#up-to-date")
    end

    # **An upgrade takes minutes and a person watches it.** The bar moves on the events
    # of the topic, so the page asks the device nothing while it runs.
    test "the bar of a download moves with the events", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/firmware")

      Event.publish(:device, %Events.UpgradeChanged{
        running: "0.1.0",
        available: "9.9.9",
        state: :installing,
        percent: 42
      })

      assert render(view) =~ "42%"
      assert has_element?(view, "#installing")
    end

    test "an upgrade that failed says so, and says the firmware is untouched", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/firmware")

      Event.publish(:device, %Events.UpgradeChanged{
        running: "0.1.0",
        available: "9.9.9",
        state: :failed,
        reason: ":wrong_digest"
      })

      html = render(view)

      assert html =~ "didn&#39;t finish"
      assert html =~ "untouched"
    end

    # **A person pressed a control, so the page owes them an answer.** A forge that a
    # device cannot reach is the common case here: a board in a house with no network
    # still draws this page.
    test "a forge that will not answer says so", %{conn: conn} do
      Req.Test.stub(Forge, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      Req.Test.allow(Forge, self(), Process.whereis(UpgradeServer))

      Application.put_env(:pifi, Forge, plug: {Req.Test, Forge}, retry: false)
      on_exit(fn -> Application.delete_env(:pifi, Forge) end)

      {:ok, view, _html} = live(conn, ~p"/settings/firmware")

      assert view |> element("#check-for-upgrade") |> render_click() =~
               "Couldn&#39;t reach the forge"
    end
  end

  # **This opens a port**, so it follows the rule that the Plex player follows: a
  # device that no person changed holds it closed. See `PiFi.HomeAssistant`.
  describe "the Home Assistant section" do
    setup do
      on_exit(fn ->
        HomeAssistant.enable(false)

        case Settings.fetch(HomeAssistant.enabled_key()) do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end)

      :ok
    end

    test "a device that no person changed says off", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/home-assistant")

      assert has_element?(view, "#toggle-home-assistant[aria-pressed='false']")
      assert render(view) =~ to_string(HomeAssistant.port())
    end

    test "a person turns it on and off again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/home-assistant")

      html = view |> element("#toggle-home-assistant") |> render_click()

      assert html =~ "can see this device now"
      assert HomeAssistant.enabled?()
      assert has_element?(view, "#toggle-home-assistant[aria-pressed='true']")

      html = view |> element("#toggle-home-assistant") |> render_click()

      assert html =~ "can no longer see this device"
      refute HomeAssistant.enabled?()
    end

    test "the menu says whether it is on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#home-assistant-row", "Off")
    end
  end

  # **A person reads the licence question on this page and nowhere else**, because
  # they are the one taking the risk. See `PiFi.Spotify`.
  describe "the Spotify section" do
    setup do
      on_exit(fn ->
        Spotify.enable(false)

        case Settings.fetch(Spotify.enabled_key()) do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end)

      :ok
    end

    test "it says what librespot is before a person turns it on", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/spotify")

      assert has_element?(view, "#toggle-spotify[aria-pressed='false']")
      assert html =~ "Premium"
      assert html =~ "librespot"
      assert html =~ "against their terms"
    end

    # The card plays one thing at a time, and a person meeting that with no warning
    # would read it as the feature being broken.
    test "it says that the card plays one thing at a time", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/spotify")

      assert html =~ "one thing at a time"
    end

    test "a person turns it on and off again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/spotify")

      html = view |> element("#toggle-spotify") |> render_click()

      assert html =~ "can cast Spotify to this device now"
      assert Spotify.enabled?()

      html = view |> element("#toggle-spotify") |> render_click()

      assert html =~ "can no longer reach this device"
      refute Spotify.enabled?()
    end

    test "the menu says whether it is on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#spotify-row", "Off")
    end
  end
end
