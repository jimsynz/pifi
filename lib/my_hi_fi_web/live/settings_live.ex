defmodule MyHiFiWeb.SettingsLive do
  @moduledoc """
  What the device holds, and what a person can change.

  Two settings change here: the output device, and the countries of the station
  list. Both stay in the database, because a device holds no environment to read a
  value from. See `MyHiFi.Settings`.

  The network state and the storage state are reports, and a person changes
  neither one here. The Wi-Fi details belong to the setup wizard. See
  `MyHiFi.Setup`.
  """

  use MyHiFiWeb, :live_view

  alias MyHiFi.Device
  alias MyHiFi.Radio.Station
  alias MyHiFi.Radio.Station.SyncFromRemote

  # The reports change without a person: a DAC arrives, Wi-Fi connects, and the
  # sync job fills the station table. The page reads them again on this interval.
  @refresh_interval :timer.seconds(5)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok, socket |> assign(:page_title, "Settings") |> load()}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("select_output", %{"id" => id}, socket) do
    case MyHiFi.Player.select_output(id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "The output device is #{id}.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not do that: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("save_countries", %{"countries" => %{"codes" => codes}}, socket) do
    case codes(codes) do
      [] ->
        {:noreply, put_flash(socket, :error, "Name at least one country, such as NZ.")}

      codes ->
        MyHiFi.Settings.put!(SyncFromRemote.countries_key(), Enum.join(codes, ","))

        {:noreply,
         socket
         |> put_flash(:info, "The station list covers #{Enum.join(codes, ", ")}.")
         |> load()}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("sync", _params, socket) do
    AshOban.schedule(Station, :sync_from_remote)

    {:noreply,
     put_flash(socket, :info, "The device asks for the station list of each country now.")}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="settings" class="mx-auto max-w-xl p-6">
      <div class="flex items-baseline justify-between mb-6">
        <h1 class="text-2xl font-semibold">Settings</h1>
        <nav class="flex gap-4 text-sm">
          <.link navigate={~p"/"} class="underline">Now playing</.link>
          <.link navigate={~p"/browse"} class="underline">Browse</.link>
        </nav>
      </div>

      <section id="output" class="mb-8">
        <h2 class="text-lg font-medium mb-2">Output device</h2>

        <p :if={@output.devices == []} id="no-output" class="text-zinc-500">
          No USB DAC is present.
        </p>

        <ul class="divide-y divide-zinc-200">
          <li
            :for={{device, index} <- Enum.with_index(@output.devices)}
            class="py-2 flex items-center gap-3"
          >
            <span class="grow">
              <span class="block">{device.title}</span>
              <span class="block text-sm text-zinc-500">{device.id}</span>
            </span>

            <span :if={device.id == @output.selected} id={"selected-#{index}"} class="text-sm">
              In use
            </span>

            <button
              :if={device.id != @output.selected}
              type="button"
              id={"select-output-#{index}"}
              phx-click="select_output"
              phx-value-id={device.id}
              class="rounded px-3 py-1 border border-zinc-400 text-sm"
            >
              Use this one
            </button>
          </li>
        </ul>
      </section>

      <section id="countries" class="mb-8">
        <h2 class="text-lg font-medium mb-2">Station countries</h2>

        <p class="text-sm text-zinc-500 mb-2">
          Name each country by its two letter code, and put a comma between them.
          The station list holds {stations(@station_count)}.
        </p>

        <.form for={@countries_form} id="countries-form" phx-submit="save_countries">
          <div class="flex gap-2">
            <.input field={@countries_form[:codes]} type="text" />
            <button type="submit" id="save-countries" class="rounded px-4 py-2 bg-zinc-800 text-white">
              Save
            </button>
          </div>
        </.form>

        <button
          type="button"
          id="sync"
          phx-click="sync"
          class="mt-3 rounded px-4 py-2 border border-zinc-400"
        >
          Ask for the stations now
        </button>
      </section>

      <section id="network" class="mb-8">
        <h2 class="text-lg font-medium mb-2">Network</h2>

        <p :if={@interfaces == []} id="no-network" class="text-zinc-500">
          The network state comes from the device.
        </p>

        <ul class="divide-y divide-zinc-200">
          <li :for={interface <- @interfaces} id={"interface-#{interface.name}"} class="py-2">
            <span class="font-medium">{interface.name}</span>
            <span class="text-sm text-zinc-500">{interface.type}</span>
            <span class="block text-sm">{connection(interface.connection)}</span>
            <span :if={interface.ssid} class="block text-sm text-zinc-600">
              {interface.ssid}, signal {interface.signal_percent}%
            </span>
            <span :if={interface.addresses != []} class="block text-sm font-mono">
              {Enum.join(interface.addresses, ", ")}
            </span>
          </li>
        </ul>
      </section>

      <section id="storage">
        <h2 class="text-lg font-medium mb-2">Storage</h2>

        <dl class="text-sm">
          <div class="flex justify-between py-1">
            <dt class="text-zinc-500">Partition</dt>
            <dd class="font-mono">{@storage.path}</dd>
          </div>
          <div class="flex justify-between py-1">
            <dt class="text-zinc-500">Free</dt>
            <dd id="free-space">{size(@storage.free_bytes)} of {size(@storage.total_bytes)}</dd>
          </div>
          <div class="flex justify-between py-1">
            <dt class="text-zinc-500">Database</dt>
            <dd id="database-size">{size(@storage.database_bytes)}</dd>
          </div>
        </dl>
      </section>
    </div>
    """
  end

  defp load(socket) do
    codes = Enum.join(SyncFromRemote.configured_countries(), ", ")

    socket
    |> refresh()
    |> assign(:countries_form, to_form(%{"codes" => codes}, as: :countries))
  end

  # The form stays out of this, because a person may be in the middle of typing a
  # country code when the interval comes round.
  defp refresh(socket) do
    socket
    |> assign(:output, MyHiFi.Player.output())
    |> assign(:interfaces, Device.network!())
    |> assign(:storage, Device.storage!())
    |> assign(:station_count, Ash.count!(Station))
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval)

  defp codes(text) do
    text
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.upcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp stations(1), do: "1 station"
  defp stations(count), do: "#{count} stations"

  defp connection(:internet), do: "Connected to the internet"
  defp connection(:lan), do: "Connected to the local network"
  defp connection(:disconnected), do: "Not connected"
  defp connection(other), do: to_string(other)

  defp size(bytes) when bytes >= 1024 * 1024 * 1024 do
    "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"
  end

  defp size(bytes) when bytes >= 1024 * 1024 do
    "#{Float.round(bytes / (1024 * 1024), 1)} MB"
  end

  defp size(bytes), do: "#{Float.round(bytes / 1024, 1)} KB"
end
