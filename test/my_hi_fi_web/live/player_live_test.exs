defmodule MyHiFiWeb.PlayerLiveTest do
  use MyHiFiWeb.ConnCase, async: false

  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events

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

  # `MyHiFiWeb.Layouts` renders the player inside each page, and it renders it with
  # `sticky: true`. A test therefore mounts a page and then asks for the child.
  defp mount_player(conn) do
    {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
    {view, find_live_child(view, "player")}
  end

  setup %{conn: conn} do
    # `MyHiFi.Player` is one process for the whole node, so its state outlives a
    # test. Each test therefore starts from a known one.
    MyHiFi.Player.standby(false)
    MyHiFi.Player.stop()

    on_exit(fn ->
      MyHiFi.Player.standby(false)
      MyHiFi.Player.stop()
    end)

    {:ok, conn: conn}
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
        source: MyHiFi.Source.InternetRadio,
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
      # station must not reach the page. See `MyHiFi.Artwork`.
      {_view, player} = mount_player(build_conn())

      Event.publish(:player, %Events.Started{
        source: MyHiFi.Source.InternetRadio,
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
        source: MyHiFi.Source.InternetRadio,
        track: track(),
        artwork_path: nil
      })

      refute has_element?(player, "#artwork")

      # `MyHiFi.Artwork.Worker` reads the logo after the track started.
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
          source: MyHiFi.Source.Podcasts,
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
          source: MyHiFi.Source.InternetRadio,
          artwork_path: nil,
          live?: true
        })

      assert player |> element("#back") |> render() =~ "disabled"
      assert player |> element("#forward") |> render() =~ "disabled"
      refute player |> element("#next") |> render() =~ "disabled"
      refute player |> element("#previous") |> render() =~ "disabled"
    end

    test "a source that a start did not name holds nothing", %{conn: conn} do
      player = expanded(conn, %Events.Started{track: track(), source: nil, artwork_path: nil})

      for control <- ["#next", "#previous", "#back", "#forward"] do
        assert player |> element(control) |> render() =~ "disabled"
      end
    end

    test "a skip control asks the player to move", %{conn: conn} do
      player =
        expanded(conn, %Events.Started{
          track: track(%{duration_ms: 600_000}),
          source: MyHiFi.Source.Podcasts,
          artwork_path: nil
        })

      assert player |> element("#back") |> render_click()
      assert player |> element("#forward") |> render_click()
    end

    test "next and previous ask the player to move", %{conn: conn} do
      player =
        expanded(conn, %Events.Started{
          track: track(),
          source: MyHiFi.Source.InternetRadio,
          artwork_path: nil
        })

      assert player |> element("#next") |> render_click()
      assert player |> element("#previous") |> render_click()
    end
  end
end
