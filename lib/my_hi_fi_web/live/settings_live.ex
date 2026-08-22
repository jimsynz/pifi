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
    case MyHiFi.Playback.select_output(id) do
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
    <div id="settings" class="space-y-4">
      <section id="output" class="glass sheen rounded-xl p-4">
        <h2 class="mb-3 text-xs uppercase tracking-[0.18em] text-ink-faint">Output device</h2>

        <p :if={@output.devices == []} id="no-output" class="text-sm text-ink-dim">
          No sound card is present.
        </p>

        <ul class="divide-y divide-edge">
          <li
            :for={{device, index} <- Enum.with_index(@output.devices)}
            class="flex items-center gap-3 py-2 first:pt-0 last:pb-0"
          >
            <.icon
              name="hero-speaker-wave"
              class={["size-5 shrink-0", if(device.id == @output.selected, do: "text-accent", else: "text-ink-faint")]}
            />

            <span class="min-w-0 grow">
              <span class="block truncate text-ink">{device.title}</span>
              <span class="numerals block truncate text-xs text-ink-faint">{device.id}</span>
            </span>

            <span
              :if={device.id == @output.selected}
              id={"selected-#{index}"}
              class="shrink-0 text-xs uppercase tracking-widest text-accent"
            >
              In use
            </span>

            <button
              :if={device.id != @output.selected}
              type="button"
              id={"select-output-#{index}"}
              phx-click="select_output"
              phx-value-id={device.id}
              class="control shrink-0 rounded-lg px-3 py-1.5 text-xs"
            >
              Use this one
            </button>
          </li>
        </ul>
      </section>

      <section id="countries" class="glass sheen rounded-xl p-4">
        <h2 class="mb-3 text-xs uppercase tracking-[0.18em] text-ink-faint">Station countries</h2>

        <p class="mb-3 text-sm text-ink-dim">
          Name each country by its two letter code, and put a comma between them.
          The station list holds {stations(@station_count)}.
        </p>

        <.form for={@countries_form} id="countries-form" phx-submit="save_countries">
          <div class="flex items-start gap-2">
            <.input field={@countries_form[:codes]} type="text" class="grow" />
            <button type="submit" id="save-countries" class="control rounded-lg px-4 py-2 text-sm">
              Save
            </button>
          </div>
        </.form>

        <button
          type="button"
          id="sync"
          phx-click="sync"
          class="control mt-3 flex items-center gap-2 rounded-lg px-4 py-2 text-sm"
        >
          <.icon name="hero-arrow-path" class="size-4" />
          Ask for the stations now
        </button>
      </section>

      <section id="network" class="glass sheen rounded-xl p-4">
        <h2 class="mb-3 text-xs uppercase tracking-[0.18em] text-ink-faint">Network</h2>

        <p :if={@interfaces == []} id="no-network" class="text-sm text-ink-dim">
          The network state comes from the device.
        </p>

        <ul class="divide-y divide-edge">
          <li
            :for={interface <- @interfaces}
            id={"interface-#{interface.name}"}
            class="py-2 first:pt-0 last:pb-0"
          >
            <div class="flex items-baseline gap-2">
              <span class="numerals text-ink">{interface.name}</span>
              <span class="text-xs uppercase tracking-widest text-ink-faint">{interface.type}</span>
            </div>
            <span class="block text-sm text-ink-dim">{connection(interface.connection)}</span>
            <span :if={interface.ssid} class="block text-sm text-ink-dim">
              {interface.ssid}, signal {interface.signal_percent}%
            </span>
            <span :if={interface.addresses != []} class="numerals block text-xs text-ink-faint">
              {Enum.join(interface.addresses, ", ")}
            </span>
          </li>
        </ul>
      </section>

      <section id="storage" class="glass sheen rounded-xl p-4">
        <h2 class="mb-3 text-xs uppercase tracking-[0.18em] text-ink-faint">Storage</h2>

        <dl class="text-sm">
          <div class="flex justify-between gap-4 border-b border-edge py-2 first:pt-0">
            <dt class="text-ink-faint">Partition</dt>
            <dd class="numerals text-ink-dim">{@storage.path}</dd>
          </div>
          <div class="flex justify-between gap-4 border-b border-edge py-2">
            <dt class="text-ink-faint">Free</dt>
            <dd id="free-space" class="numerals text-ink-dim">
              {size(@storage.free_bytes)} of {size(@storage.total_bytes)}
            </dd>
          </div>
          <div class="flex justify-between gap-4 py-2 last:pb-0">
            <dt class="text-ink-faint">Database</dt>
            <dd id="database-size" class="numerals text-ink-dim">{size(@storage.database_bytes)}</dd>
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
    |> assign(:output, MyHiFi.Playback.output!())
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
