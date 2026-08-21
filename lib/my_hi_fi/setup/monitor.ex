# `vintage_net` is a target dependency, so the host build must hold no reference
# to this module.
if Mix.target() != :host do
  defmodule MyHiFi.Setup.Monitor do
    @moduledoc """
    Watches for the end of setup mode.

    The wizard runs its `:on_exit` callback only when a browser asks for the last
    page of the wizard. That page is out of reach in the usual case. A person
    applies a network, the device leaves access point mode, and the telephone then
    loses that access point. The browser cannot ask for the last page, so the
    callback does not happen. The wizard stops after its inactivity timeout of 10
    minutes, and the device is of no use until then.

    This process watches the VintageNet configuration instead. Access point mode
    ends as soon as the wizard applies a network, and the device then restarts into
    normal operation.
    """

    use GenServer

    require Logger

    @property ["interface", "wlan0", "config"]

    @doc false
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl GenServer
    def init(_opts) do
      :ok = VintageNet.subscribe(@property)
      {:ok, %{}}
    end

    @impl GenServer
    def handle_info({VintageNet, @property, _old, new, _meta}, state) do
      if wifi_configured?(new) do
        Logger.info("The wizard applied a Wi-Fi network. Setup mode is over.")
        MyHiFi.Setup.finished()
      end

      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}

    # A restart happens only for a configuration that holds a real network. An
    # access point network, or a configuration with no network at all, means that
    # setup continues.
    defp wifi_configured?(%{vintage_net_wifi: %{networks: [_ | _] = networks}}) do
      Enum.all?(networks, &(&1[:mode] != :ap))
    end

    defp wifi_configured?(_config), do: false
  end
end
