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

      Event.publish(:player, %Events.Started{track: track(), source: nil, artwork_path: nil})
      assert render(player) =~ "RNZ National"

      Event.publish(:player, %Events.Stopped{reason: :requested})

      html = render(player)
      assert html =~ "Idle"
      assert html =~ "Nothing selected"
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
end
