defmodule MyHiFiWeb.SettingsLiveTest do
  use MyHiFiWeb.ConnCase, async: false
  use Oban.Testing, repo: MyHiFi.Repo

  alias MyHiFi.Radio
  alias MyHiFi.Radio.Station.SyncFromRemote
  alias MyHiFi.Settings

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
    on_exit(fn ->
      # The settings outlive a test, because they are rows and not process state.
      for key <- [SyncFromRemote.countries_key(), MyHiFi.Player.output_device_key()] do
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

    test "says when no USB DAC is present", %{conn: conn} do
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
      # No USB DAC is present on a host, so the page shows no control. The player
      # holds the choice all the same, and it is the part that a device needs.
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
end
