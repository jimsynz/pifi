defmodule MyHiFi.Setup do
  @moduledoc """
  Wi-Fi setup for a device with no display.

  A new device holds no Wi-Fi details. It makes its own access point, and a
  person gives the details on a web page. VintageNetWizard does that work, and
  VintageNet keeps the details after a restart.

  Setup and normal operation cannot happen together. The wizard serves on port
  80, and its captive portal needs port 80 as well. `MyHiFiWeb.Endpoint` uses the
  same port. `MyHiFi.Application` therefore starts one or the other, and never
  both.
  """

  @doc """
  Start the wizard if the device holds no Wi-Fi configuration.

  It gives `:running` for setup mode, and `:not_needed` for normal operation. The
  host always gives `:not_needed`.

  An error also gives `:not_needed`. A board that cannot make an access point
  must still start the web interface, because a person can then reach the device
  over Ethernet or over USB.
  """
  @spec start() :: :running | :not_needed
  def start, do: do_start()

  @doc """
  Restart the device after the wizard stops.

  The wizard holds port 80, so the web interface cannot start while the wizard
  runs. A restart is the simplest way into normal operation, and it takes about
  12 seconds.

  The wizard also stops after a time with no activity. The device then restarts,
  finds no Wi-Fi configuration, and offers the access point again.
  """
  @spec finished() :: :ok
  def finished, do: do_finished()

  # `vintage_net_wizard` is a target dependency, so the host build must hold no
  # reference to it.
  if Mix.target() == :host do
    defp do_start, do: :not_needed

    defp do_finished, do: :ok
  else
    require Logger

    alias Nerves.Runtime.KV

    defp do_start do
      case VintageNetWizard.run_if_unconfigured(
             on_exit: {__MODULE__, :finished, []},
             device_info: device_info(),
             ui: [title: "MyHiFi"]
           ) do
        :configured ->
          :not_needed

        :ok ->
          Logger.info("No Wi-Fi configuration. The setup access point is in operation.")
          :running

        {:error, reason} ->
          Logger.error("The setup access point did not start: #{inspect(reason)}")
          :not_needed
      end
    end

    defp do_finished do
      Logger.info("Wi-Fi setup is complete. The device restarts now.")
      Nerves.Runtime.reboot()
    end

    defp device_info do
      [
        {"Serial number", Nerves.Runtime.serial_number()},
        {"Firmware version", KV.get_active("nerves_fw_version")},
        {"Firmware UUID", KV.get_active("nerves_fw_uuid")}
      ]
    end
  end
end
