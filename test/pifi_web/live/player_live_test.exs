defmodule PiFiWeb.PlayerLiveTest do
  use PiFiWeb.ConnCase, async: false

  alias PiFi.Artwork.Thumbnail
  alias PiFi.Event
  alias PiFi.Event.Player, as: Events

  defp track(overrides \\ %{}) do
    Map.merge(
      %{
        ref: {:station, Ash.UUID.generate()},
        title: "RNZ National",
        subtitle: "MP3, 64 kbps",
        artwork: "https://example.test/logo.png",
        duration_ms: nil
      },
      overrides
    )
  end

  # `PiFiWeb.Layouts` renders the player inside each page, and it renders it with
  # `sticky: true`. A test therefore mounts a page and then asks for the child.
  defp mount_player(conn) do
    {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
    {view, find_live_child(view, "player")}
  end

  setup %{conn: conn} do
    # `PiFi.Player` is one process for the whole node, so its state outlives a
    # test. Each test therefore starts from a known one.
    PiFi.Player.standby(false)
    PiFi.Player.stop()

    on_exit(fn ->
      PiFi.Player.standby(false)
      PiFi.Player.stop()
    end)

    {:ok, conn: conn}
  end

  describe "the accent colour" do
    # The device reads the picture when it makes the thumbnail, and the page draws
    # what the device found. The page holds no reader of its own now. See
    # `PiFi.Artwork.Accent`.
    test "the page is told the colour of the artwork that plays", %{conn: conn} do
      {_view, player} = mount_player(conn)

      hash = String.duplicate("c", 64)

      {:ok, entry} =
        PiFi.Cache.put("artwork", hash, %{bytes: "a picture", content_type: "image/jpeg"})

      PiFi.Cache.put!("artwork", hash <> ".thumbnail", %{
        bytes: "a small picture",
        content_type: "image/jpeg",
        metadata: %{accent: %{lightness: 0.78, chroma: 0.15, hue: 74.0}},
        variant_of_blob_id: entry.id,
        variant_name: "thumbnail",
        variant_digest: Thumbnail.digest()
      })

      on_exit(fn -> PiFi.Cache.purge(entry) end)

      Event.publish(:player, %Events.MetadataChanged{artwork_path: "/artwork/" <> hash})

      assert_push_event(player, "accent", %{colour: "oklch(0.78 0.15 74.0)"})
    end

    test "a track with no artwork gives the page no colour", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Stopped{reason: :requested})

      assert_push_event(player, "accent", %{colour: nil})
    end
  end

  describe "mount" do
    test "shows that nothing plays", %{conn: conn} do
      {_view, player} = mount_player(conn)
      html = render(player)

      assert html =~ "Idle"
      assert html =~ "Nothing selected"
      assert html =~ "--:--"
    end
  end

  describe "the events of the player" do
    test "buffering shows before there is sound", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Buffering{percent: 0})

      assert render(player) =~ "Buffering"
    end

    test "a started track shows its title and station", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Started{
        source: PiFi.Source.InternetRadio,
        track: track(),
        artwork_path: nil
      })

      html = render(player)
      assert html =~ "Playing"
      assert html =~ "RNZ National"
      assert html =~ "MP3, 64 kbps"
    end

    test "the logo comes from this device, and never from the station" do
      # The content security policy holds `'self'` alone, so the address of the
      # station must not reach the page. See `PiFi.Artwork`.
      {_view, player} = mount_player(build_conn())

      Event.publish(:player, %Events.Started{
        source: PiFi.Source.InternetRadio,
        track: track(),
        artwork_path: "/artwork/#{String.duplicate("a", 64)}.png"
      })

      html = render(player)

      assert html =~ "/artwork/#{String.duplicate("a", 64)}.png"
      refute html =~ "https://example.test/logo.png"
    end

    test "a logo that arrives after the track shows without a reload", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Started{
        source: PiFi.Source.InternetRadio,
        track: track(),
        artwork_path: nil
      })

      refute has_element?(player, "#artwork")

      # `PiFi.Artwork.Worker` reads the logo after the track started.
      Event.publish(:player, %Events.MetadataChanged{
        artwork_path: "/artwork/#{String.duplicate("b", 64)}.png"
      })

      assert render(player) =~ "/artwork/#{String.duplicate("b", 64)}.png"
    end

    test "a live stream shows the time from the start and no length", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Started{track: track(), source: nil, artwork_path: nil})
      Event.publish(:player, %Events.Progress{position_ms: 65_000, duration_ms: nil})

      html = render(player)
      assert html =~ "01:05"
      refute html =~ "01:05 /"
    end

    test "a track with a length shows both times", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Started{track: track(), source: nil, artwork_path: nil})
      Event.publish(:player, %Events.Progress{position_ms: 5_000, duration_ms: 180_000})

      assert render(player) =~ "00:05 / 03:00"
    end

    test "a new stream title shows above the station", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Started{track: track(), source: nil, artwork_path: nil})
      Event.publish(:player, %Events.MetadataChanged{title: "Some Song", artist: nil})

      html = render(player)
      assert html =~ "Some Song"
      assert html =~ "RNZ National"
    end

    test "a stop returns the page to idle", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Started{
        track: track(),
        source: nil,
        artwork_path: "/artwork/station.png"
      })

      html = render(player)
      assert html =~ "RNZ National"
      assert html =~ "/artwork/station.png"

      Event.publish(:player, %Events.Stopped{reason: :requested})

      html = render(player)
      assert html =~ "Idle"
      assert html =~ "Nothing selected"
      refute html =~ "/artwork/station.png"
    end

    test "a fault shows the reason", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Failed{reason: :too_many_restarts})

      html = render(player)
      assert html =~ "Stopped"
      assert html =~ "too_many_restarts"
    end

    test "standby changes what the button offers", %{conn: conn} do
      {_view, player} = mount_player(conn)

      assert render(player) =~ "Standby"

      Event.publish(:player, %Events.Standby{entered?: true})

      assert render(player) =~ "Leave standby"
    end
  end

  describe "the controls" do
    test "stop is not offered while nothing plays", %{conn: conn} do
      {_view, player} = mount_player(conn)

      assert player |> element("#stop") |> render() =~ "disabled"
    end

    test "stop asks the player to stop", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Started{track: track(), source: nil, artwork_path: nil})
      render(player)

      assert player |> element("#stop") |> render_click()
      assert render(player) =~ "Idle"
    end

    test "standby asks the player for standby", %{conn: conn} do
      {_view, player} = mount_player(conn)

      assert player |> element("#standby") |> render_click()
      assert render(player) =~ "Leave standby"
    end
  end

  # A device in standby offers one control, and the control is the power button. See
  # `PiFiWeb.Shell`.
  describe "standby" do
    defp enter_standby(view) do
      PiFi.Player.standby(true)
      render(view)
    end

    test "the source controls and the settings control go dead", %{conn: conn} do
      {view, _player} = mount_player(conn)

      assert has_element?(view, "a#source-internet-radio")
      assert has_element?(view, "a#settings-link")

      enter_standby(view)

      refute has_element?(view, "a#source-internet-radio")
      refute has_element?(view, "a#settings-link")
      assert has_element?(view, "span#source-internet-radio[aria-disabled=true]")
      assert has_element?(view, "span#settings-link[aria-disabled=true]")
    end

    test "the area under the faceplate holds nothing", %{conn: conn} do
      {view, _player} = mount_player(conn)

      assert has_element?(view, "main")

      enter_standby(view)

      refute has_element?(view, "main")
    end

    test "the page comes back when the device wakes", %{conn: conn} do
      {view, _player} = mount_player(conn)
      enter_standby(view)

      PiFi.Player.standby(false)
      render(view)

      assert has_element?(view, "main")
      assert has_element?(view, "a#source-internet-radio")
    end

    test "the power button is the one control of the faceplate that lives", %{conn: conn} do
      {view, player} = mount_player(conn)
      enter_standby(view)
      render(player)

      assert has_element?(player, "#artwork-button[disabled]")
      assert has_element?(player, "#play-pause[disabled]")
      assert has_element?(player, "#stop[disabled]")
      refute has_element?(player, "#standby[disabled]")
    end

    test "the power button brings the page back", %{conn: conn} do
      {view, player} = mount_player(conn)
      enter_standby(view)
      refute has_element?(view, "main")

      player |> element("#standby") |> render_click()
      render(view)

      assert has_element?(view, "main")
    end

    # The large view fills the screen, so a view that stayed open would cover the one
    # control that standby leaves alive.
    test "the large view closes", %{conn: conn} do
      {view, player} = mount_player(conn)

      player |> element("#artwork-button") |> render_click()
      assert has_element?(player, "#expanded")

      enter_standby(view)
      render(player)

      refute has_element?(player, "#expanded")
    end
  end

  describe "the play control" do
    test "it is not offered while nothing is selected", %{conn: conn} do
      {_view, player} = mount_player(conn)

      assert player |> element("#play-pause") |> render() =~ "disabled"
    end

    test "a track that plays offers a pause", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Started{track: track(), source: nil, artwork_path: nil})

      html = player |> element("#play-pause") |> render()
      assert html =~ "hero-pause"
      assert html =~ "Pause"
    end

    test "a track that is paused offers a play", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Started{track: track(), source: nil, artwork_path: nil})
      render(player)
      Event.publish(:player, %Events.Paused{position_ms: 90_000})

      html = render(player)
      assert html =~ "Paused"
      assert html =~ "RNZ National"
      assert html =~ "01:30"

      assert player |> element("#play-pause") |> render() =~ "hero-play"
    end

    test "a pause asks the player to pause", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Started{track: track(), source: nil, artwork_path: nil})
      render(player)

      assert player |> element("#play-pause") |> render_click()
    end

    # A resume begins in the middle of an episode, and the first progress event
    # arrives one second later.
    test "a start shows the place that the audio began at", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:player, %Events.Started{
        track: track(%{duration_ms: 600_000}),
        source: nil,
        artwork_path: nil,
        position_ms: 305_000
      })

      assert render(player) =~ "05:05"
    end
  end

  describe "the transport row of the large view" do
    defp expanded(conn, event) do
      {_view, player} = mount_player(conn)
      Event.publish(:player, event)
      render(player)
      player |> element("#artwork-button") |> render_click()

      player
    end

    test "a podcast episode holds every control", %{conn: conn} do
      player =
        expanded(conn, %Events.Started{
          track: track(%{duration_ms: 600_000}),
          source: PiFi.Source.Podcasts,
          artwork_path: nil
        })

      refute player |> element("#next") |> render() =~ "disabled"
      refute player |> element("#previous") |> render() =~ "disabled"
      refute player |> element("#back") |> render() =~ "disabled"
      refute player |> element("#forward") |> render() =~ "disabled"
    end

    # A radio stream has no place, so the two skip controls are dead. Next and previous
    # move through the favourite stations.
    test "a radio station holds no skip", %{conn: conn} do
      player =
        expanded(conn, %Events.Started{
          track: track(),
          source: PiFi.Source.InternetRadio,
          artwork_path: nil,
          live?: true
        })

      assert player |> element("#back") |> render() =~ "disabled"
      assert player |> element("#forward") |> render() =~ "disabled"
      refute player |> element("#next") |> render() =~ "disabled"
      refute player |> element("#previous") |> render() =~ "disabled"
    end

    # The skip controls belong to the source, and next and previous belong to the queue,
    # so a track with no source still steps through the list.
    test "a source that a start did not name holds no skip", %{conn: conn} do
      player = expanded(conn, %Events.Started{track: track(), source: nil, artwork_path: nil})

      for control <- ["#back", "#forward"] do
        assert player |> element(control) |> render() =~ "disabled"
      end

      for control <- ["#next", "#previous"] do
        refute player |> element(control) |> render() =~ "disabled"
      end
    end

    # A person drags the thumb of the timeline, and the browser sends the place that
    # they let it go at.
    test "the timeline draws for a track that holds a length", %{conn: conn} do
      player =
        expanded(conn, %Events.Started{
          track: track(%{duration_ms: 600_000}),
          source: PiFi.Source.Podcasts,
          artwork_path: nil
        })

      Event.publish(:player, %Events.Progress{position_ms: 30_000, duration_ms: 600_000})
      render(player)

      assert has_element?(player, "#timeline-position[max='600000'][value='30000']")
      refute has_element?(player, "#timeline-position[disabled]")
    end

    test "a live stream draws no timeline", %{conn: conn} do
      player =
        expanded(conn, %Events.Started{
          track: track(),
          source: PiFi.Source.InternetRadio,
          artwork_path: nil,
          live?: true
        })

      refute has_element?(player, "#timeline")
    end

    # A track with a length that a person cannot move inside still says how far through
    # it they are.
    test "a track that holds no skip draws the timeline dead", %{conn: conn} do
      player =
        expanded(conn, %Events.Started{
          track: track(%{duration_ms: 600_000}),
          source: nil,
          artwork_path: nil
        })

      Event.publish(:player, %Events.Progress{position_ms: 1_000, duration_ms: 600_000})
      render(player)

      assert has_element?(player, "#timeline-position[disabled]")
    end

    test "the timeline asks the player to move to the place that a person chose", %{conn: conn} do
      player =
        expanded(conn, %Events.Started{
          track: track(%{duration_ms: 600_000}),
          source: PiFi.Source.Podcasts,
          artwork_path: nil
        })

      Event.publish(:player, %Events.Progress{position_ms: 10_000, duration_ms: 600_000})
      render(player)

      player |> form("#timeline", %{"position_ms" => "90000"}) |> render_change()

      assert has_element?(player, "#timeline-position[value='90000']")
    end

    # **The player publishes the progress once a second, and a person holding the thumb
    # keeps it.** A page that took every event would take the control out of their hand.
    test "an event of the progress leaves the thumb alone while a person holds it", %{conn: conn} do
      player =
        expanded(conn, %Events.Started{
          track: track(%{duration_ms: 600_000}),
          source: PiFi.Source.Podcasts,
          artwork_path: nil
        })

      Event.publish(:player, %Events.Progress{position_ms: 10_000, duration_ms: 600_000})
      render(player)

      player |> element("#timeline-position") |> render_focus()

      Event.publish(:player, %Events.Progress{position_ms: 11_000, duration_ms: 600_000})
      render(player)

      assert has_element?(player, "#timeline-position[value='10000']")

      player |> element("#timeline-position") |> render_blur()

      Event.publish(:player, %Events.Progress{position_ms: 12_000, duration_ms: 600_000})
      render(player)

      assert has_element?(player, "#timeline-position[value='12000']")
    end

    test "a skip control asks the player to move", %{conn: conn} do
      player =
        expanded(conn, %Events.Started{
          track: track(%{duration_ms: 600_000}),
          source: PiFi.Source.Podcasts,
          artwork_path: nil
        })

      assert player |> element("#back") |> render_click()
      assert player |> element("#forward") |> render_click()
    end

    test "next and previous ask the player to move", %{conn: conn} do
      player =
        expanded(conn, %Events.Started{
          track: track(),
          source: PiFi.Source.InternetRadio,
          artwork_path: nil
        })

      assert player |> element("#next") |> render_click()
      assert player |> element("#previous") |> render_click()
    end
  end

  describe "the battery" do
    # A device on the mains holds no gauge and publishes no charge, so a page on that
    # device draws no battery at all. Never a battery at 0.
    test "a device that reports no charge draws none", %{conn: conn} do
      {_view, player} = mount_player(conn)

      refute has_element?(player, "#battery")
    end

    test "a charge that arrives draws one", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:device, %PiFi.Event.Device.BatteryChanged{
        percent: 64,
        volts: 3.9,
        low?: false
      })

      html = render(player)

      assert html =~ "Battery 64 percent"
      assert has_element?(player, "#battery")
    end

    test "a cell that is low draws in the warning colour", %{conn: conn} do
      {_view, player} = mount_player(conn)

      Event.publish(:device, %PiFi.Event.Device.BatteryChanged{
        percent: 8,
        volts: 3.5,
        low?: true
      })

      html = render(player)

      assert html =~ "Battery 8 percent"
      assert html =~ "rose-400"
    end
  end
end
