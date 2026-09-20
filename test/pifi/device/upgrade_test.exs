defmodule PiFi.Device.UpgradeTest do
  use PiFi.DataCase, async: false

  doctest PiFi.Device.Upgrade, import: true

  alias PiFi.Device
  alias PiFi.Device.Upgrade
  alias PiFi.Device.Upgrade.Server
  alias PiFi.Event
  alias PiFi.Event.Device.UpgradeChanged

  setup do
    # `PiFi.Device.Upgrade.Server` is one process for the whole node, so what one test
    # learns from the forge is what the next one reads. This gives each test a device
    # that has checked nothing.
    restart = fn ->
      :ok = Supervisor.terminate_child(PiFi.Supervisor, Server)
      {:ok, _pid} = Supervisor.restart_child(PiFi.Supervisor, Server)
    end

    restart.()
    on_exit(restart)

    :ok
  end

  # **The request leaves the state process and not the test.** A stub of `Req.Test`
  # belongs to the process that made it, so the server needs the allowance.
  defp forge(fun) do
    Req.Test.stub(Upgrade.Forge, fun)
    Req.Test.allow(Upgrade.Forge, self(), Process.whereis(Server))
    Application.put_env(:pifi, Upgrade.Forge, plug: {Req.Test, Upgrade.Forge})

    on_exit(fn -> Application.delete_env(:pifi, Upgrade.Forge) end)
  end

  defp release(version, assets) do
    %{
      "tag_name" => "v#{version}",
      "body" => "What changed.",
      "assets" =>
        Enum.map(assets, fn name ->
          %{"name" => name, "browser_download_url" => "https://example.test/#{name}"}
        end)
    }
  end

  defp assets, do: [Upgrade.firmware_name(), Upgrade.firmware_name() <> ".sha256"]

  defp later_than_running do
    %Version{major: major} = Version.parse!(Upgrade.running_version())

    "#{major + 1}.0.0"
  end

  describe "what a device knows before it asks" do
    test "it names the version that runs and no other" do
      report = Device.upgrade!()

      assert report.running == Upgrade.running_version()
      assert report.available == nil
      assert report.checked_at == nil
      assert report.state == :idle
    end
  end

  describe "asking the forge" do
    test "a newer release is one that a person can install" do
      version = later_than_running()
      forge(fn conn -> Req.Test.json(conn, release(version, assets())) end)

      assert {:ok, report} = Device.check_for_upgrade()
      assert report.available == version
      assert report.notes == "What changed."
      assert report.checked_at
    end

    # A device that a person put a later build on by hand must not be told to go back to
    # the tag of the forge.
    test "a release that is not newer is no upgrade" do
      forge(fn conn -> Req.Test.json(conn, release("0.0.1", assets())) end)

      assert {:ok, report} = Device.check_for_upgrade()
      assert report.available == nil
    end

    # A tag of a version before this target existed carries no firmware for it.
    test "a release with no firmware for this target names nothing" do
      forge(fn conn -> Req.Test.json(conn, release(later_than_running(), ["pifi-other.fw"])) end)

      assert {:error, error} = Device.check_for_upgrade()
      assert Exception.message(error) =~ "no_firmware"
      assert Device.upgrade!().available == nil
    end

    test "a repository with no release at all is not an error that a person reads twice" do
      forge(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, error} = Device.check_for_upgrade()
      assert Exception.message(error) =~ "no_release"

      # It still records that it asked, so the page says when it last tried.
      assert Device.upgrade!().checked_at
    end

    # **The read has to finish inside the call that `PiFi.Device.Upgrade.Server`
    # makes.** `Req` retries a transient fault three times by default, and at the 20
    # seconds an attempt that this used to allow the worst case was 87 seconds against
    # a call that waits 30. The forge went quiet, the call timed out, and the caller
    # died: the page of the person who pressed the control, or the job of the schedule.
    test "a forge that will not answer gives up rather than outlast the caller" do
      counter = :counters.new(1, [])

      forge(fn conn ->
        :counters.add(counter, 1, 1)
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, _reason} = Device.check_for_upgrade()

      # One attempt and one retry, and no more.
      assert :counters.get(counter, 1) == 2
    end

    test "a check tells every open page" do
      Event.subscribe(:device)
      version = later_than_running()
      forge(fn conn -> Req.Test.json(conn, release(version, assets())) end)

      {:ok, _report} = Device.check_for_upgrade()

      assert_receive %UpgradeChanged{available: ^version}, 2000
    end
  end

  describe "installing" do
    test "a device that knows of nothing newer installs nothing" do
      assert {:error, _reason} = Device.install_upgrade()
    end

    # A host holds no partition to write, so the work refuses and the state says why.
    # The card of a device is the only place that this can be measured for real.
    test "a host refuses the work and says so" do
      Event.subscribe(:device)
      forge(fn conn -> Req.Test.json(conn, release(later_than_running(), assets())) end)

      {:ok, _report} = Device.check_for_upgrade()

      assert {:ok, :ok} = Device.install_upgrade()

      assert_receive %UpgradeChanged{state: :failed, reason: reason}, 5000
      assert reason =~ "not_a_device"
    end
  end
end
