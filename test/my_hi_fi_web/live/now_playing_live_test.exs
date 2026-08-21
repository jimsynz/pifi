defmodule MyHiFiWeb.NowPlayingLiveTest do
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
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Now playing"
      assert html =~ "Idle"
      assert html =~ "Nothing selected"
      assert html =~ "--:--"
    end
  end

  describe "the events of the player" do
    test "buffering shows before there is sound", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Event.publish(:player, %Events.Buffering{percent: 0})

      assert render(view) =~ "Buffering"
    end

    test "a started track shows its title, station and artwork", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Event.publish(:player, %Events.Started{
        source: MyHiFi.Source.InternetRadio,
        track: track(),
        artwork_path: nil
      })

      html = render(view)
      assert html =~ "Playing"
      assert html =~ "RNZ National"
      assert html =~ "MP3, 64 kbps"
      assert html =~ "https://example.test/logo.png"
    end

    test "a live stream shows the time from the start and no length", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Event.publish(:player, %Events.Started{track: track(), source: nil, artwork_path: nil})
      Event.publish(:player, %Events.Progress{position_ms: 65_000, duration_ms: nil})

      html = render(view)
      assert html =~ "01:05"
      refute html =~ "01:05 /"
    end

    test "a track with a length shows both times", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Event.publish(:player, %Events.Started{track: track(), source: nil, artwork_path: nil})
      Event.publish(:player, %Events.Progress{position_ms: 5_000, duration_ms: 180_000})

      assert render(view) =~ "00:05 / 03:00"
    end

    test "a new stream title shows above the station", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Event.publish(:player, %Events.Started{track: track(), source: nil, artwork_path: nil})
      Event.publish(:player, %Events.MetadataChanged{title: "Some Song", artist: nil})

      html = render(view)
      assert html =~ "Some Song"
      assert html =~ "RNZ National"
    end

    test "a stop returns the page to idle", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Event.publish(:player, %Events.Started{track: track(), source: nil, artwork_path: nil})
      assert render(view) =~ "RNZ National"

      Event.publish(:player, %Events.Stopped{reason: :requested})

      html = render(view)
      assert html =~ "Idle"
      assert html =~ "Nothing selected"
    end

    test "a fault shows the reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Event.publish(:player, %Events.Failed{reason: :too_many_restarts})

      html = render(view)
      assert html =~ "Stopped"
      assert html =~ "too_many_restarts"
    end

    test "standby changes what the button offers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert render(view) =~ "Standby"

      Event.publish(:player, %Events.Standby{entered?: true})

      assert render(view) =~ "Leave standby"
    end
  end

  describe "the controls" do
    test "stop is not offered while nothing plays", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#stop") |> render() =~ "disabled"
    end

    test "stop asks the player to stop", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Event.publish(:player, %Events.Started{track: track(), source: nil, artwork_path: nil})
      render(view)

      assert view |> element("#stop") |> render_click()
      assert render(view) =~ "Idle"
    end

    test "standby asks the player for standby", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#standby") |> render_click()
      assert render(view) =~ "Leave standby"
    end
  end
end
