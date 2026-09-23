defmodule PiFiWeb.SettingsLive do
  @moduledoc """
  What the device is, and what a person can change.

  The page is a menu, and each row of it opens one section. The address names the
  section, so a person can keep the address of one and the back control of the
  browser moves out of it.

      /settings                        the menu
      /settings/device                 the name and the picture of the device
      /settings/output                 the sound card
      /settings/sources                the sources, and which ones are in use
      /settings/sources/internet-radio one source
      /settings/peripherals            the screens and the controls of the board
      /settings/crossfade              how long one track plays under the next
      /settings/timezone               which part of the world the device is in
      /settings/standby                the period of quiet, and the switch off
      /settings/network                a report
      /settings/storage                a report
      /settings/firmware               the version that runs, and the one that could
      /settings/home-assistant         whether a house can see this device

  **This page needs no knowledge of any source.** A source names its own settings
  with `c:PiFi.Source.settings/0`, and its own controls with
  `c:PiFi.Source.settings_actions/0`. The countries of the station list belong to
  internet radio, and the key of the Podcast Index belongs to podcasts. A new
  source therefore reaches this page without a change here.

  The page never sends the secret of an index back to a browser. A source marks
  such a field `write_only?`, and it then gives no value for it.

  It needs no knowledge of any peripheral either. A peripheral names itself with
  `c:PiFi.Peripheral.title/0`, and this page draws that name and one control. A
  peripheral is out of use until a person says that the part is wired, because the same
  image runs on a board with a screen and on a board with none. See
  `PiFi.Peripheral`.

  The name of the device and the picture of the idle screen are the two things on this
  page that reach the hardware and the network together, and `PiFi.Device.Identity`
  declares both. This page gives the name to that module, and it draws what comes back.

  The network state and the storage state are reports, and a person changes neither
  one here. The Wi-Fi details belong to the setup wizard. See `PiFi.Setup`.

  **The reports arrive, and this page asks for none of them.** A DAC arrives, Wi-Fi
  connects, and a download fills the card, so the three reports change without a
  person. This page read all three every five seconds before, which was eleven queries
  each time for an answer that almost never moved. `PiFi.Device.Monitor` owns the
  three sources of truth now and publishes on the `:device` topic. This page reads once
  when a person opens it, because no event has arrived yet, and after that it draws what
  it is told.
  """

  use PiFiWeb, :live_view

  # Sobelow reads `@sobelow_skip` from the source. This registration stops the
  # compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  alias PiFi.AirPlay.Server, as: AirPlay
  alias PiFi.AutoSync
  alias PiFi.Bluetooth
  alias PiFi.Device
  alias PiFi.Device.Identity
  alias PiFi.Device.Timezone
  alias PiFi.Event
  alias PiFi.Event.Device, as: Events
  alias PiFi.Hardware
  alias PiFi.HomeAssistant
  alias PiFi.Peripheral
  alias PiFi.Player.Crossfade
  alias PiFi.Source
  alias PiFi.SwitchOff

  # **BlueZ ends a scan by itself after a while**, so the control goes back to saying
  # "Look for devices" rather than claiming to still be looking. Generous, because a
  # board found a headset at twenty-five seconds.
  @bluetooth_scan :timer.seconds(30)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Event.subscribe(:device)

    # One picture, and 4 MB, which is the limit that `PiFi.Artwork` sets for a
    # picture of any kind. A GIF and a WebP are absent because libvips in this firmware
    # writes neither, so a screen could never draw one. See `PiFi.Artwork.put/1`.
    #
    # **The upload starts when a person chooses the file, and `progress` receives it when
    # the last byte lands.** A control that a person presses cannot do this work: the
    # board reads 4 MB over Wi-Fi in more time than a person waits, and
    # `Phoenix.LiveView.consume_uploaded_entries/3` raises `cannot consume uploaded
    # files when entries are still in progress` for an upload that is still going. A
    # device on this network logged that from a real press.
    socket =
      allow_upload(socket, :splash,
        accept: ~w(.jpg .jpeg .png),
        max_entries: 1,
        max_file_size: 4 * 1024 * 1024,
        auto_upload: true,
        progress: &splash_progress/3
      )

    {:ok, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"source" => slug}, _uri, socket) do
    case Source.from_slug(slug) do
      {:ok, module} -> {:noreply, socket |> title() |> load_source(module)}
      {:error, :not_a_source} -> {:noreply, push_navigate(socket, to: ~p"/settings/sources")}
    end
  end

  # **A device with no screen has no page about one.** A person reaches this address
  # from a device that had a panel and then lost it, or by typing it, and the menu that
  # they came from is the honest place to send them.
  @impl Phoenix.LiveView
  def handle_params(_params, _uri, %{assigns: %{live_action: :screen, screen?: false}} = socket) do
    {:noreply, push_navigate(socket, to: ~p"/settings")}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket), do: {:noreply, title(socket)}

  # Each event carries the whole report, so this draws it and reads nothing. The page
  # keeps the plain map that `refresh/1` assigns, so no part below here knows whether
  # the answer came from a read or from an event.
  @impl Phoenix.LiveView
  def handle_info(%Events.NetworkChanged{interfaces: interfaces}, socket) do
    {:noreply, assign(socket, :interfaces, interfaces)}
  end

  @impl Phoenix.LiveView
  # **A headset connecting changes the output list and this page as well.** The same
  # event carries both: `PiFi.Bluetooth.Watcher` publishes it when a device arrives or
  # goes. See `PiFi.Player.outputs_changed/0`.
  def handle_info(%Events.OutputChanged{} = event, socket) do
    socket = assign(socket, :output, Map.take(event, [:devices, :selected, :in_use]))

    {:noreply, assign(socket, :bluetooth_devices, bluetooth_devices())}
  end

  def handle_info(:bluetooth_scanned, socket) do
    {:noreply, socket |> assign(:bluetooth_scanning?, false) |> refresh()}
  end

  def handle_info({:bluetooth_done, outcome, result}, socket) do
    socket = socket |> assign(:bluetooth_busy, nil) |> refresh()

    {:noreply, bluetooth_said(socket, outcome, result)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.IdentityChanged{} = event, socket) do
    {:noreply,
     socket
     |> assign(:device_name, event.name)
     |> assign(:device_slug, Identity.slug(event.name))
     |> assign(:splash_path, event.splash_path)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.StorageChanged{} = event, socket) do
    fields = [:path, :total_bytes, :free_bytes, :used_bytes, :database_bytes, :full?]

    {:noreply, socket |> assign(:storage, Map.take(event, fields)) |> assign_usage()}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.UpgradeChanged{} = event, socket) do
    fields = [:running, :available, :notes, :checked_at, :state, :percent, :reason]

    {:noreply, assign(socket, :upgrade, Map.take(event, fields))}
  end

  # The player publishes on this topic as well, and no report of this page changes with
  # it.
  @impl Phoenix.LiveView
  def handle_info(_message, socket), do: {:noreply, socket}

  # **A check answers when the forge does**, and a person pressed a control, so this
  # waits for it and says what happened. A daily job asks the same question with nobody
  # watching. See `PiFi.Device.Upgrade.Check`.
  @impl Phoenix.LiveView
  def handle_event("check_for_upgrade", _params, socket) do
    case Device.check_for_upgrade() do
      {:ok, report} ->
        {:noreply, socket |> assign(:upgrade, report) |> put_flash(:info, check_message(report))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't reach the forge. Try again in a moment.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("install_upgrade", _params, socket) do
    case Device.install_upgrade() do
      {:ok, _result} ->
        {:noreply, assign(socket, :upgrade, Device.upgrade!())}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "There's nothing to install.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_home_assistant", _params, socket) do
    enabled? = not socket.assigns.home_assistant?
    :ok = HomeAssistant.enable(enabled?)

    message =
      if enabled?,
        do: "Home Assistant can see this device now.",
        else: "Home Assistant can no longer see this device."

    {:noreply, socket |> assign(:home_assistant?, enabled?) |> put_flash(:info, message)}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_bluetooth", _params, socket) do
    enabled? = not socket.assigns.bluetooth?

    case Bluetooth.enable(enabled?) do
      :ok ->
        message = if enabled?, do: "Bluetooth is on.", else: "Bluetooth is off."

        {:noreply,
         socket |> assign(:bluetooth?, enabled?) |> put_flash(:info, message) |> refresh()}

      # Saying it is on while three daemons failed to start would send a person looking
      # for a headset that this device cannot see.
      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:bluetooth?, false)
         |> put_flash(:error, "Bluetooth did not start.")
         |> refresh()}
    end
  end

  # **A scan takes about half a minute and BlueZ ends it by itself.** The control says
  # so rather than appearing to have found nothing, and pressing it again is safe:
  # `PiFi.Bluetooth.Devices.discover/0` answers a scan that is already running with
  # `:ok`.
  @impl Phoenix.LiveView
  def handle_event("scan_bluetooth", _params, socket) do
    case Bluetooth.Devices.discover() do
      :ok ->
        Process.send_after(self(), :bluetooth_scanned, @bluetooth_scan)

        {:noreply, assign(socket, :bluetooth_scanning?, true)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not look for devices.")}
    end
  end

  # **Pairing waits for a person to press a button on a headset**, so it cannot run
  # here: a `GenServer.call` that takes twenty seconds is a page that answers nothing
  # for twenty seconds. The work goes to a task and the answer comes back as a message.
  @impl Phoenix.LiveView
  def handle_event("pair_bluetooth", %{"path" => path}, socket) do
    {:noreply, bluetooth_task(socket, path, :paired, fn -> Bluetooth.Devices.pair(path) end)}
  end

  @impl Phoenix.LiveView
  def handle_event("forget_bluetooth", %{"path" => path}, socket) do
    {:noreply, bluetooth_task(socket, path, :forgotten, fn -> Bluetooth.Devices.forget(path) end)}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_airplay", _params, socket) do
    enabled? = not socket.assigns.airplay?

    case AirPlay.enable(enabled?) do
      :ok ->
        message =
          if enabled?,
            do: "You can send audio to this device over AirPlay now.",
            else: "AirPlay is off."

        {:noreply, socket |> assign(:airplay?, enabled?) |> put_flash(:info, message)}

      # Saying it is on while nothing is listening would send a person looking at their
      # telephone for a device that was never there.
      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:airplay?, false)
         |> put_flash(:error, "AirPlay couldn't start. Something else may be using the port.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("save_device_name", %{"device" => %{"name" => name}}, socket) do
    case Identity.put_name(name) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Renamed to #{Identity.name()}.") |> refresh()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # A file input needs a change event of its own, and the answer is the upload that
  # LiveView already has. Nothing here reads the parameters.
  @impl Phoenix.LiveView
  def handle_event("validate_splash", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("remove_splash", _params, socket) do
    :ok = Identity.remove_splash()

    {:noreply,
     socket
     |> put_flash(:info, "Each screen shows the default picture again.")
     |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_event("enable_source", %{"slug" => slug, "enabled" => enabled}, socket) do
    with {:ok, module} <- Source.from_slug(slug),
         {:ok, :ok} <- PiFi.Playback.enable_source(module, enabled == "true") do
      {:noreply, socket |> put_flash(:info, in_use(module)) |> reload(module)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't do that: #{inspect(reason)}")}
    end
  end

  # A peripheral that a person turns on opens a bus, and a bus with nothing on it gives
  # an error. That error is the answer to the question that they asked, so it reaches
  # the page and not the log alone. The setting stays as they asked either way, so a
  # screen that they wire afterwards comes up on the next boot.
  @impl Phoenix.LiveView
  def handle_event("enable_peripheral", %{"slug" => slug, "enabled" => enabled}, socket) do
    with {:ok, module} <- Peripheral.from_slug(slug),
         :ok <- Peripheral.enable(module, enabled == "true") do
      {:noreply, socket |> put_flash(:info, peripheral_in_use(module)) |> refresh()}
    else
      {:error, :not_a_peripheral} ->
        {:noreply, push_navigate(socket, to: ~p"/settings/peripherals")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Couldn't start that: #{inspect(reason)}")
         |> refresh()}
    end
  end

  # The device restarts when the write succeeds, so a person reads no answer at all in
  # that case. A write that failed leaves them on this page with the reason.
  @impl Phoenix.LiveView
  def handle_event("choose_hardware", %{"id" => id}, socket) do
    case Hardware.choose(id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:profile, Hardware.chosen())
         |> put_flash(:info, "Restarting to apply that.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "That didn't work: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("run_source_action", %{"name" => name}, socket) do
    module = socket.assigns.source.module

    case Source.run_settings_action(module, name) do
      {:ok, message} -> {:noreply, socket |> put_flash(:info, message) |> reload(module)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("save_source", %{"source" => values}, socket) do
    module = socket.assigns.source.module

    case Source.put_settings(module, values) do
      {:ok, message} -> {:noreply, socket |> put_flash(:info, message) |> reload(module)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("set_sync_hours", %{"key" => key, "hours" => hours}, socket) do
    module = socket.assigns.source.module

    case AutoSync.set_hours(key, String.to_integer(hours)) do
      :ok ->
        {:noreply, socket |> put_flash(:info, sync_flash(key, hours)) |> load_source(module)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "That didn't work: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_volume", _params, socket) do
    enabled? = not socket.assigns.volume.enabled?

    {:ok, _result} = PiFi.Playback.enable_volume(enabled?)

    {:noreply, socket |> put_flash(:info, volume_flash(enabled?)) |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_switch_off", _params, socket) do
    :ok = SwitchOff.enable(not socket.assigns.switch_off?)

    {:noreply,
     socket |> put_flash(:info, switch_off_flash(not socket.assigns.switch_off?)) |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_event("set_standby_minutes", %{"minutes" => minutes}, socket) do
    case PiFi.Playback.set_standby_minutes(String.to_integer(minutes)) do
      {:ok, :ok} ->
        {:noreply, socket |> put_flash(:info, standby_flash(minutes)) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't change the period: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("set_timezone", %{"timezone" => timezone}, socket) do
    case Device.set_timezone(String.trim(timezone)) do
      {:ok, :ok} ->
        {:noreply, socket |> put_flash(:info, timezone_flash(timezone)) |> refresh()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "PiFi doesn't know a place called #{timezone}.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("set_crossfade_seconds", %{"seconds" => seconds}, socket) do
    case PiFi.Playback.set_crossfade_seconds(String.to_integer(seconds)) do
      {:ok, :ok} ->
        {:noreply, socket |> put_flash(:info, crossfade_flash(seconds)) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't change the crossfade: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("set_screen_blank_seconds", %{"seconds" => seconds}, socket) do
    case PiFi.Playback.set_screen_blank_seconds(String.to_integer(seconds)) do
      {:ok, :ok} ->
        {:noreply, socket |> put_flash(:info, screen_flash(seconds)) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't change the period: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("select_output", %{"id" => id}, socket) do
    case PiFi.Playback.select_output(id) do
      {:ok, :ok} ->
        {:noreply, socket |> put_flash(:info, "Now using #{id}.") |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't do that: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :menu} = assigns) do
    ~H"""
    <div id="settings" class="glass sheen divide-y divide-edge rounded-xl">
      <.row id="device-row" to={~p"/settings/device"} icon="ph-identification-card" title="Device">
        {@device_name}
      </.row>

      <.row id="output-row" to={~p"/settings/output"} icon="ph-speaker-high" title="Output device">
        {output_summary(@output)}
      </.row>

      <.row
        id="crossfade-row"
        to={~p"/settings/crossfade"}
        icon="ph-wave-triangle"
        title="Crossfade"
      >
        {crossfade_summary(@crossfade_seconds)}
      </.row>

      <.row id="sources-row" to={~p"/settings/sources"} icon="ph-queue" title="Sources">
        {sources_summary(@source_list)}
      </.row>

      <.row
        id="peripherals-row"
        to={~p"/settings/peripherals"}
        icon="ph-cpu"
        title="Peripherals"
      >
        {peripherals_summary(@peripheral_list)}
      </.row>

      <.row id="timezone-row" to={~p"/settings/timezone"} icon="ph-globe-hemisphere-west" title="Time zone">
        {timezone_summary(@clock)}
      </.row>

      <.row id="standby-row" to={~p"/settings/standby"} icon="ph-moon" title="Standby">
        {standby_summary(@standby_minutes)}
      </.row>

      <.row
        :if={@screen?}
        id="screen-row"
        to={~p"/settings/screen"}
        icon="ph-lightbulb"
        title="Screen"
      >
        {screen_summary(@screen_blank_seconds)}
      </.row>


      <.row id="network-row" to={~p"/settings/network"} icon="ph-wifi-high" title="Network">
        {network_summary(@interfaces)}
      </.row>

      <.row
        id="storage-row"
        to={~p"/settings/storage"}
        icon="ph-database"
        title="Storage"
      >
        {size(@storage.free_bytes)} free of {size(@storage.total_bytes)}
      </.row>

      <.row
        id="firmware-row"
        to={~p"/settings/firmware"}
        icon="ph-arrow-circle-up"
        title="Firmware"
      >
        {firmware_summary(@upgrade)}
      </.row>

      <.row
        id="home-assistant-row"
        to={~p"/settings/home-assistant"}
        icon="ph-house-line"
        title="Home Assistant"
      >
        {if @home_assistant?, do: "On", else: "Off"}
      </.row>

      <.row id="airplay-row" to={~p"/settings/airplay"} icon="ph-airplay" title="AirPlay">
        {if @airplay?, do: "On", else: "Off"}
      </.row>

      <.row
        :if={@bluetooth_adapter?}
        id="bluetooth-row"
        to={~p"/settings/bluetooth"}
        icon="ph-bluetooth"
        title="Bluetooth"
      >
        {bluetooth_summary(@bluetooth?, @bluetooth_devices)}
      </.row>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :device} = assigns) do
    ~H"""
    <.section id="settings-device" title="Device" back={~p"/settings"}>
      <p class="mb-3 text-sm text-ink-dim">
        This name shows up on the network, on the device's screen, and on the Wi-Fi
        access point during setup. Give two of them different names.
      </p>

      <.form for={@device_form} id="device-form" phx-submit="save_device_name">
        <.input field={@device_form[:name]} type="text" label="Name" maxlength="32" />

        <p class="mt-1 text-sm text-ink-dim">
          PiFi is reachable at <span class="numerals">{@device_slug}.local</span>, and at
          the name the board shipped with. Up to 32 characters.
        </p>

        <button type="submit" id="save-device-name" class="control mt-3 rounded-lg px-4 py-2 text-sm">
          Save
        </button>
      </.form>

      <div class="mt-4 border-t border-edge pt-4">
        <p class="mb-3 text-sm text-ink-dim">
          Shown on the screen when nothing is playing. JPEG or PNG, up to 4096 KB.
        </p>

        <img
          :if={@splash_path}
          id="splash"
          src={@splash_path}
          alt="Shown on the screen when nothing is playing"
          class="mb-3 max-h-40 rounded-lg"
        />

        <p :if={is_nil(@splash_path)} id="no-splash" class="mb-3 text-sm text-ink-dim">
          No picture set, so each screen shows the device name.
        </p>

        <.form for={@splash_form} id="splash-form" phx-change="validate_splash">
          <.live_file_input upload={@uploads.splash} class="text-sm text-ink-dim" />

          <p
            :for={error <- upload_errors(@uploads.splash)}
            class="mt-1 text-sm text-danger"
          >
            {upload_message(error)}
          </p>

          <div :for={entry <- @uploads.splash.entries} class="mt-2 text-sm text-ink-dim">
            <p>{entry.client_name}</p>

            <p
              :for={error <- upload_errors(@uploads.splash, entry)}
              class="text-danger"
            >
              {upload_message(error)}
            </p>
          </div>

          <button
            :if={@splash_path}
            type="button"
            id="remove-splash"
            phx-click="remove_splash"
            class="control mt-3 rounded-lg px-4 py-2 text-sm"
          >
            Remove the picture
          </button>
        </.form>
      </div>
    </.section>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :output} = assigns) do
    ~H"""
    <.section id="settings-output" title="Output device" back={~p"/settings"}>
      <p :if={@output.devices == []} id="no-output" class="text-sm text-ink-dim">
        No sound card found.
      </p>

      <p :if={absent_choice?(@output)} id="absent-output" class="mb-3 text-sm text-ink-dim">
        The card you chose isn't connected, so PiFi is using the first one.
      </p>

      <ul class="divide-y divide-edge">
        <li :for={{device, index} <- Enum.with_index(@output.devices)}>
          <.output_device
            device={device}
            index={index}
            in_use?={device.id == @output.in_use}
            by_default?={is_nil(@output.selected)}
          />
        </li>
      </ul>

      <div id="volume-control" class="mt-4 border-t border-edge pt-4">
        <button
          type="button"
          id="toggle-volume"
          phx-click="toggle_volume"
          disabled={not @volume.supported?}
          aria-pressed={to_string(@volume.enabled?)}
          class={[
            "flex w-full items-center gap-3 text-left",
            @volume.enabled? && "text-accent",
            not @volume.supported? && "opacity-50"
          ]}
        >
          <span class={[
            "flex size-5 shrink-0 items-center justify-center rounded-full",
            if(@volume.enabled?,
              do: "bg-accent/15 shadow-[inset_0_0_0_1px_var(--color-accent)]",
              else: "shadow-[inset_0_0_0_1px_var(--color-edge)]"
            )
          ]}>
            <span :if={@volume.enabled?} class="size-2 rounded-full bg-accent" />
          </span>

          <span class="min-w-0 grow">Set the volume on this device</span>
        </button>

        <p :if={@volume.supported?} class="mt-1 text-sm text-ink-dim">
          Digital volume works by throwing bits away, so leave this off if you are
          feeding an amplifier and use its knob instead. Turn it on for headphones or
          powered speakers, which have nowhere else to set the level. Turning it off
          puts the card back to full volume.
        </p>

        <p :if={not @volume.supported?} id="no-volume-control" class="mt-1 text-sm text-ink-dim">
          This card has no volume control PiFi can set. Most hi-fi DACs are fixed
          output by design. Use your amplifier instead.
        </p>
      </div>

      <.link
        navigate={~p"/settings/output/hardware"}
        id="hardware-link"
        class="mt-4 flex items-center gap-2 border-t border-edge pt-4 text-sm text-ink-dim hover:text-accent"
      >
        <.icon name="ph-question" class="size-4 shrink-0" />
        Can't see your audio device?
      </.link>
    </.section>
    """
  end

  # A DAC on the I2S pins answers to nothing until the bootloader loads an overlay for
  # it, so no list of cards names one and no control of this page finds one. A person
  # names what they added instead. See `PiFi.Hardware`.
  @impl Phoenix.LiveView
  def render(%{live_action: :hardware} = assigns) do
    ~H"""
    <.section id="settings-hardware" title="Audio hardware" back={~p"/settings/output"}>
      <p class="mb-4 text-sm text-ink-dim">
        A DAC wired to the board's pins needs a driver that loads before the rest of the
        firmware. Tell PiFi what you fitted and it restarts to load it.
      </p>

      <ul class="divide-y divide-edge">
        <li :for={profile <- @profiles} class="py-3">
          <button
            type="button"
            id={"profile-#{profile.id}"}
            phx-click="choose_hardware"
            phx-value-id={profile.id}
            disabled={profile.id == @profile.id}
            class="group flex w-full items-center gap-3 text-left"
          >
            <.icon
              name={if profile.id == @profile.id, do: "ph-check-circle", else: "ph-database"}
              class={[
                "size-5 shrink-0",
                if(profile.id == @profile.id, do: "text-accent", else: "text-ink-faint")
              ]}
            />
            <span class="min-w-0 grow">
              <span class={[
                "block",
                if(profile.id == @profile.id, do: "text-accent", else: "text-ink group-hover:text-accent")
              ]}>
                {profile.title}
              </span>
              <span class="block text-sm text-ink-faint">{profile.description}</span>
            </span>
          </button>
        </li>
      </ul>
    </.section>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :sources} = assigns) do
    ~H"""
    <.section id="settings-sources" title="Sources" back={~p"/settings"}>
      <p class="mb-3 text-sm text-ink-dim">
        A disabled source drops off the top row and stops talking to the network.
      </p>

      <ul class="divide-y divide-edge">
        <li
          :for={source <- @source_list}
          id={"source-row-#{source.slug}"}
          class="flex items-center gap-3 py-2 first:pt-0 last:pb-0"
        >
          <.source_icon
            name={source.icon}
            class={["size-5 shrink-0", if(source.enabled?, do: "text-accent", else: "text-ink-faint")]}
          />

          <.link navigate={~p"/settings/sources/#{source.slug}"} class="min-w-0 grow">
            <span class="block truncate text-ink">{source.title}</span>
            <span class="block truncate text-xs text-ink-faint">{state(source.enabled?)}</span>
          </.link>

          <.use_control source={source} />

          <.icon name="ph-caret-right" class="size-5 shrink-0 text-ink" />
        </li>
      </ul>
    </.section>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :source} = assigns) do
    ~H"""
    <.section id="settings-source" title={@source.title} back={~p"/settings/sources"}>
      <div class="mb-4 flex items-center gap-3 border-b border-edge pb-4">
        <.source_icon
          name={@source.icon}
          class={["size-5 shrink-0", if(@source.enabled?, do: "text-accent", else: "text-ink-faint")]}
        />
        <span class="grow text-sm text-ink-dim">{state(@source.enabled?)}</span>
        <.use_control source={@source} />
      </div>

      <div :if={@source.description != []} id="source-description" class="mb-4 space-y-2">
        <p :for={paragraph <- @source.description} class={["text-sm", paragraph_class(paragraph)]}>
          {paragraph_text(paragraph)}
        </p>
      </div>

      <p :if={@source.fields == [] and @source.actions == []} id="no-source-settings" class="text-sm text-ink-dim">
        {@source.title} has nothing else to change.
      </p>

      <.form :if={@source.fields != []} for={@source.form} id="source-form" phx-submit="save_source">
        <div class="space-y-3">
          <div :for={field <- @source.fields}>
            <.input
              field={@source.form[field.key]}
              type={to_string(field.type)}
              label={field.title}
              placeholder={placeholder(field)}
            />
            <p :if={field.description} class="mt-1 text-sm text-ink-dim">
              {field.description}
              <a
                :if={field.link}
                href={field.link.href}
                class="text-accent underline"
                rel="noopener"
              >{field.link.title}</a>
            </p>
          </div>
        </div>

        <button type="submit" id="save-source" class="control mt-3 rounded-lg px-4 py-2 text-sm">
          Save
        </button>
      </.form>

      <div :if={@source.actions != []} class="mt-4 space-y-3 border-t border-edge pt-4">
        <div :for={action <- @source.actions}>
          <button
            type="button"
            id={"source-action-#{action.name}"}
            phx-click="run_source_action"
            phx-value-name={action.name}
            class="control flex items-center gap-2 rounded-lg px-4 py-2 text-sm"
          >
            <.source_icon name={action.icon} class="size-4" />
            {action.title}
          </button>
          <p :if={action.description} class="mt-1 text-sm text-ink-dim">{action.description}</p>
        </div>
      </div>

      <div :if={@source.jobs != []} id="source-syncing" class="mt-4 border-t border-edge pt-4">
        <p class="mb-3 text-sm text-ink-dim">
          PiFi checks for new items once the interval has passed and the network is up,
          so one that is off overnight catches up when you switch it on.
        </p>

        <div :for={job <- @source.jobs} id={"sync-#{job.key}"} class="mb-3">
          <p class="text-sm font-medium text-ink">{job.title}</p>
          <p class="mb-2 text-sm text-ink-dim">{job.description}</p>

          <div class="flex flex-wrap gap-1">
            <button
              :for={hours <- sync_periods()}
              type="button"
              id={"sync-#{job.key}-#{hours}"}
              phx-click="set_sync_hours"
              phx-value-key={job.key}
              phx-value-hours={hours}
              class={[
                "control rounded-lg px-2 py-1 text-sm",
                hours == job.hours && "text-accent"
              ]}
            >
              {sync_period_title(hours)}
            </button>
          </div>

          <p class="mt-2 text-xs text-ink-faint">{last_run_title(job.last_run)}</p>
        </div>
      </div>
    </.section>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :peripherals} = assigns) do
    ~H"""
    <.section id="settings-peripherals" title="Peripherals" back={~p"/settings"}>
      <p class="mb-3 text-sm text-ink-dim">
        The same firmware runs on boards with a screen and boards without, so it cannot
        tell what yours has. Turn on the parts you wired up.
      </p>

      <p :if={@peripheral_list == []} id="no-peripherals" class="text-sm text-ink-dim">
        No peripherals are configured.
      </p>

      <ul class="divide-y divide-edge">
        <li
          :for={peripheral <- @peripheral_list}
          id={"peripheral-row-#{peripheral.slug}"}
          class="flex items-center gap-3 py-2 first:pt-0 last:pb-0"
        >
          <.icon
            name="ph-cpu"
            class={[
              "size-5 shrink-0",
              if(peripheral.running?, do: "text-accent", else: "text-ink-faint")
            ]}
          />

          <span class="min-w-0 grow">
            <span class="block truncate text-ink">{peripheral.title}</span>
            <span class="block truncate text-xs text-ink-faint">
              {peripheral_state(peripheral)}
            </span>
          </span>

          <button
            type="button"
            id={"enable-peripheral-#{peripheral.slug}"}
            phx-click="enable_peripheral"
            phx-value-slug={peripheral.slug}
            phx-value-enabled={to_string(not peripheral.enabled?)}
            class={[
              "control shrink-0 rounded-lg px-3 py-1.5 text-xs",
              peripheral.enabled? && "control-on"
            ]}
          >
            {if peripheral.enabled?, do: "Disable", else: "Enable"}
          </button>
        </li>
      </ul>
    </.section>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :timezone} = assigns) do
    ~H"""
    <.section id="settings-timezone" title="Time zone" back={~p"/settings"}>
      <p class="mb-3 text-sm text-ink-dim">
        PiFi keeps every time in UTC and shows it to you in the place you name here. It
        also decides when overnight work happens: PiFi looks for a new firmware at
        {Device.Upgrade.Check.hour()} in the morning, your time.
      </p>

      <p class="mb-4 text-sm text-ink-dim">
        Name a place and not an offset. A place carries the daylight saving rule with it,
        so PiFi stays right through both ends of the year.
      </p>

      <form id="timezone-form" phx-submit="set_timezone" class="mb-4 flex items-center gap-2">
        <input
          type="text"
          id="timezone-name"
          name="timezone"
          value={@clock.timezone}
          list="timezone-options"
          required
          autocomplete="off"
          spellcheck="false"
          aria-label="Time zone"
          class="control grow rounded-lg px-3 py-2 text-sm"
        />
        <datalist id="timezone-options">
          <option :for={zone <- @clock.common} value={zone}></option>
        </datalist>
        <button type="submit" id="save-timezone" class="control rounded-lg px-3 py-2 text-sm">
          Save
        </button>
      </form>

      <p id="timezone-now" class="text-sm text-ink-dim">
        It is {Calendar.strftime(@clock.now, "%A %-d %B, %H:%M")} in {@clock.timezone}.
      </p>
    </.section>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :crossfade} = assigns) do
    ~H"""
    <.section id="settings-crossfade" title="Crossfade" back={~p"/settings"}>
      <p class="mb-3 text-sm text-ink-dim">
        The end of one track plays under the start of the next, the first getting
        quieter while the second gets louder. It suits a playlist of songs. Leave it off
        for podcasts and live recordings, where it talks over the first word and takes
        the silence off the end.
      </p>

      <p class="mb-4 text-sm text-ink-dim">
        It applies between two tracks of the queue. A radio station never ends, so it
        never fades, and two tracks recorded at different sample rates play one after
        the other as they always did.
      </p>

      <ul class="divide-y divide-edge">
        <li :for={seconds <- Crossfade.lengths()}>
          <button
            type="button"
            id={"crossfade-length-#{seconds}"}
            phx-click="set_crossfade_seconds"
            phx-value-seconds={seconds}
            class={[
              "flex w-full items-center gap-3 py-2 text-left",
              seconds == @crossfade_seconds && "text-accent"
            ]}
          >
            <span class={[
              "flex size-5 shrink-0 items-center justify-center rounded-full",
              if(seconds == @crossfade_seconds,
                do: "bg-accent/15 shadow-[inset_0_0_0_1px_var(--color-accent)]",
                else: "shadow-[inset_0_0_0_1px_var(--color-edge)]"
              )
            ]}>
              <span :if={seconds == @crossfade_seconds} class="size-2 rounded-full bg-accent" />
            </span>

            <span class="min-w-0 grow truncate">{crossfade_title(seconds)}</span>
          </button>
        </li>
      </ul>
    </.section>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :standby} = assigns) do
    ~H"""
    <.section id="settings-standby" title="Standby" back={~p"/settings"}>
      <p class="mb-3 text-sm text-ink-dim">
        PiFi goes into standby after this long with nothing playing and no button
        pressed. Playback keeps it awake, so a two-hour episode always finishes.
      </p>

      <div id="switch-off" class="mb-4 border-b border-edge pb-4">
        <button
          type="button"
          id="toggle-switch-off"
          phx-click="toggle_switch_off"
          aria-pressed={to_string(@switch_off?)}
          class={["flex w-full items-center gap-3 text-left", @switch_off? && "text-accent"]}
        >
          <span class={[
            "flex size-5 shrink-0 items-center justify-center rounded-full",
            if(@switch_off?,
              do: "bg-accent/15 shadow-[inset_0_0_0_1px_var(--color-accent)]",
              else: "shadow-[inset_0_0_0_1px_var(--color-edge)]"
            )
          ]}>
            <span :if={@switch_off?} class="size-2 rounded-full bg-accent" />
          </span>

          <span class="min-w-0 grow">Prepare for switch-off</span>
        </button>

        <p class="mt-1 text-sm text-ink-dim">
          A battery device gets switched off by hand. Turn this on and PiFi stops its
          background work when it enters standby, writes everything to the card, and says
          on the screen when it is safe to switch off. Leave it off for a mains-powered
          device, which can keep working in standby.
        </p>
      </div>

      <ul class="divide-y divide-edge">
        <li :for={minutes <- periods()}>
          <button
            type="button"
            id={"standby-period-#{minutes}"}
            phx-click="set_standby_minutes"
            phx-value-minutes={minutes}
            class={[
              "flex w-full items-center gap-3 py-2 text-left",
              minutes == @standby_minutes && "text-accent"
            ]}
          >
            <span class={[
              "flex size-5 shrink-0 items-center justify-center rounded-full",
              if(minutes == @standby_minutes,
                do: "bg-accent/15 shadow-[inset_0_0_0_1px_var(--color-accent)]",
                else: "shadow-[inset_0_0_0_1px_var(--color-edge)]"
              )
            ]}>
              <span :if={minutes == @standby_minutes} class="size-2 rounded-full bg-accent" />
            </span>

            <span class="min-w-0 grow truncate">{period_title(minutes)}</span>
          </button>
        </li>
      </ul>
    </.section>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :screen} = assigns) do
    ~H"""
    <.section id="settings-screen" title="Screen" back={~p"/settings"}>
      <p class="mb-3 text-sm text-ink-dim">
        The screen goes dark after this long without a button press. Playback carries
        on, so this is not standby. Any button wakes it, and that first press does
        nothing else.
      </p>

      <p class="mb-3 text-sm text-ink-dim">
        The backlight is a big part of what a battery device draws. Pick a short period
        if you carry it around, or <em>Never</em>
        if it sits on a shelf showing what is playing.
      </p>

      <ul class="divide-y divide-edge">
        <li :for={seconds <- blank_periods()}>
          <button
            type="button"
            id={"screen-period-#{seconds}"}
            phx-click="set_screen_blank_seconds"
            phx-value-seconds={seconds}
            class={[
              "flex w-full items-center gap-3 py-2 text-left",
              seconds == @screen_blank_seconds && "text-accent"
            ]}
          >
            <span class={[
              "flex size-5 shrink-0 items-center justify-center rounded-full",
              if(seconds == @screen_blank_seconds,
                do: "bg-accent/15 shadow-[inset_0_0_0_1px_var(--color-accent)]",
                else: "shadow-[inset_0_0_0_1px_var(--color-edge)]"
              )
            ]}>
              <span :if={seconds == @screen_blank_seconds} class="size-2 rounded-full bg-accent" />
            </span>

            <span class="min-w-0 grow truncate">{blank_title(seconds)}</span>
          </button>
        </li>
      </ul>
    </.section>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :network} = assigns) do
    ~H"""
    <.section id="settings-network" title="Network" back={~p"/settings"}>
      <p :if={@interfaces == []} id="no-network" class="text-sm text-ink-dim">
        No network interfaces found.
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
    </.section>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :storage} = assigns) do
    ~H"""
    <.section id="settings-storage" title="Storage" back={~p"/settings"}>
      <.usage_bar usage={@usage} used_bytes={@storage.used_bytes} />

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

      <p :if={@storage.full?} id="storage-warning" class="mt-3 text-sm text-danger">
        This partition is nearly full.
      </p>
    </.section>
    """
  end

  # **An upgrade takes minutes and it restarts the device**, so this page says what is
  # happening the whole way through rather than go quiet. The state arrives on the
  # `:device` topic, so the bar moves with no interval of its own. See
  # `PiFi.Device.Upgrade`.
  @impl Phoenix.LiveView
  def render(%{live_action: :firmware} = assigns) do
    ~H"""
    <.section id="settings-firmware" title="Firmware" back={~p"/settings"}>
      <dl class="text-sm">
        <div class="flex justify-between gap-4 border-b border-edge py-2 first:pt-0">
          <dt class="text-ink-faint">Running</dt>
          <dd id="running-version" class="numerals text-ink-dim">{@upgrade.running}</dd>
        </div>
        <div class="flex justify-between gap-4 py-2 last:pb-0">
          <dt class="text-ink-faint">Checked</dt>
          <dd id="checked-at" class="text-ink-dim">{checked_text(@upgrade.checked_at)}</dd>
        </div>
      </dl>

      <p :if={is_nil(@upgrade.available)} id="up-to-date" class="mt-3 text-sm text-ink-dim">
        This is the newest firmware.
      </p>

      <div :if={@upgrade.available} id="available" class="mt-3">
        <p class="display text-ink">Version {@upgrade.available} is ready.</p>
        <pre
          :if={@upgrade.notes != ""}
          id="release-notes"
          class="mt-2 max-h-48 overflow-y-auto whitespace-pre-wrap text-sm text-ink-dim"
        >{@upgrade.notes}</pre>
      </div>

      <div :if={@upgrade.state == :installing} id="installing" class="mt-3">
        <p class="text-sm text-ink-dim">Reading the firmware. {@upgrade.percent}%</p>
        <div class="mt-2 h-3 w-full overflow-hidden rounded-full bg-shell">
          <div class="h-full bg-accent" style={"width: #{@upgrade.percent}%"}></div>
        </div>
      </div>

      <p :if={@upgrade.state == :installed} id="installed" class="mt-3 text-sm text-ink-dim">
        The firmware is written. PiFi is restarting.
      </p>

      <p :if={@upgrade.state == :failed} id="upgrade-failed" class="mt-3 text-sm text-danger">
        That upgrade didn't finish, and the firmware you have is untouched. {@upgrade.reason}
      </p>

      <div class="mt-4 flex gap-2">
        <button
          id="check-for-upgrade"
          type="button"
          phx-click="check_for_upgrade"
          disabled={@upgrade.state == :installing}
          class="control rounded-lg px-3 py-2 text-sm disabled:opacity-50"
        >
          Check now
        </button>

        <button
          :if={@upgrade.available}
          id="install-upgrade"
          type="button"
          phx-click="install_upgrade"
          disabled={@upgrade.state in [:installing, :installed]}
          data-confirm="PiFi will restart once the firmware is written."
          class="control control-on rounded-lg px-3 py-2 text-sm disabled:opacity-50"
        >
          Install {@upgrade.available}
        </button>
      </div>
    </.section>
    """
  end

  # **This opens a port**, so the page says which one and what a person gets for it.
  # See `PiFi.HomeAssistant`.
  @impl Phoenix.LiveView
  def render(%{live_action: :home_assistant} = assigns) do
    ~H"""
    <.section id="settings-home-assistant" title="Home Assistant" back={~p"/settings"}>
      <p class="text-sm text-ink-dim">
        Home Assistant finds this device on your network and draws it as a media player,
        so it can go on a dashboard and an automation can pause the music.
      </p>

      <p class="mt-2 text-sm text-ink-dim">
        The device listens on port {HomeAssistant.port()} while this is on, and on no
        port at all while it is off.
      </p>

      <div class="mt-4">
        <button
          id="toggle-home-assistant"
          type="button"
          phx-click="toggle_home_assistant"
          aria-pressed={to_string(@home_assistant?)}
          class={[
            "control rounded-lg px-3 py-2 text-sm",
            if(@home_assistant?, do: "control-on", else: "")
          ]}
        >
          {if @home_assistant?, do: "Disable", else: "Enable"}
        </button>
      </div>
    </.section>
    """
  end

  # **A radio that answers anything in range**, so the page says what turning it on
  # means. Choosing where audio goes stays on the output page: a paired headset appears
  # there by itself. See `PiFi.Bluetooth`.
  @impl Phoenix.LiveView
  def render(%{live_action: :bluetooth} = assigns) do
    ~H"""
    <.section id="settings-bluetooth" title="Bluetooth" back={~p"/settings"}>
      <p class="text-sm text-ink-dim">
        Pair a speaker or a pair of headphones. Once paired, it shows up under
        <.link navigate={~p"/settings/output"} class="underline">Output device</.link>
        whenever it is switched on.
      </p>

      <p class="mt-2 text-sm text-ink-dim">
        Bluetooth carries SBC only, so a headset will not sound as good as the USB DAC.
      </p>

      <div class="mt-4 flex gap-2">
        <button
          id="toggle-bluetooth"
          type="button"
          phx-click="toggle_bluetooth"
          aria-pressed={to_string(@bluetooth?)}
          class={[
            "control rounded-lg px-3 py-2 text-sm",
            if(@bluetooth?, do: "control-on", else: "")
          ]}
        >
          {if @bluetooth?, do: "Disable", else: "Enable"}
        </button>

        <button
          :if={@bluetooth?}
          id="scan-bluetooth"
          type="button"
          phx-click="scan_bluetooth"
          disabled={@bluetooth_scanning?}
          class="control rounded-lg px-3 py-2 text-sm disabled:opacity-50"
        >
          {if @bluetooth_scanning?, do: "Looking…", else: "Look for devices"}
        </button>
      </div>

      <p :if={@bluetooth_scanning?} id="bluetooth-looking" class="mt-3 text-sm text-ink-dim">
        Hold the button on your headphones until the light flashes. This takes about half
        a minute.
      </p>

      <p
        :if={@bluetooth? and not @bluetooth_scanning? and @bluetooth_devices == []}
        id="no-bluetooth-devices"
        class="mt-3 text-sm text-ink-dim"
      >
        Nothing paired yet. Put your headphones into pairing mode and look for devices.
      </p>

      <ul :if={@bluetooth_devices != []} class="mt-3 divide-y divide-edge">
        <li
          :for={device <- @bluetooth_devices}
          id={"bluetooth-#{bluetooth_slug(device)}"}
          class="flex items-center gap-3 py-2 first:pt-0 last:pb-0"
        >
          <.icon
            name={if device.connected?, do: "ph-bluetooth-connected", else: "ph-bluetooth"}
            class={[
              "size-5 shrink-0",
              if(device.connected?, do: "text-accent", else: "text-ink-faint")
            ]}
          />

          <span class="min-w-0 grow">
            <span class="block truncate text-ink">{device.name}</span>
            <span class="block truncate text-xs text-ink-faint">
              {bluetooth_state(device, @bluetooth_busy)}
            </span>
          </span>

          <button
            :if={not device.paired?}
            type="button"
            id={"pair-#{bluetooth_slug(device)}"}
            phx-click="pair_bluetooth"
            phx-value-path={device.path}
            disabled={@bluetooth_busy != nil}
            class="control shrink-0 rounded-lg px-3 py-1.5 text-xs disabled:opacity-50"
          >
            Pair
          </button>

          <button
            :if={device.paired?}
            type="button"
            id={"forget-#{bluetooth_slug(device)}"}
            phx-click="forget_bluetooth"
            phx-value-path={device.path}
            disabled={@bluetooth_busy != nil}
            data-confirm={"PiFi will forget #{device.name}. You can pair it again."}
            class="control shrink-0 rounded-lg px-3 py-1.5 text-xs disabled:opacity-50"
          >
            Forget
          </button>
        </li>
      </ul>
    </.section>
    """
  end

  # **This opens a port too**, so the page says the same things the Home Assistant one
  # does. See `PiFi.AirPlay.Server`.
  @impl Phoenix.LiveView
  def render(%{live_action: :airplay} = assigns) do
    ~H"""
    <.section id="settings-airplay" title="AirPlay" back={~p"/settings"}>
      <p class="text-sm text-ink-dim">
        Send audio to this device from an iPhone, an iPad or a Mac. It appears in the
        AirPlay list the same way a speaker does.
      </p>

      <p class="mt-2 text-sm text-ink-dim">
        The device listens on port {AirPlay.port()} while this is on, and on no port at
        all while it is off. Anyone on your network can send to it, which is how AirPlay
        works everywhere.
      </p>

      <div class="mt-4">
        <button
          id="toggle-airplay"
          type="button"
          phx-click="toggle_airplay"
          aria-pressed={to_string(@airplay?)}
          class={["control rounded-lg px-3 py-2 text-sm", if(@airplay?, do: "control-on", else: "")]}
        >
          {if @airplay?, do: "Disable", else: "Enable"}
        </button>
      </div>
    </.section>
    """
  end

  attr(:usage, :list, required: true)
  attr(:used_bytes, :integer, required: true)

  # One bar of the space in use, and one row for each kind of media in it.
  #
  # **The bar spans what is in use and not the whole partition.** A card of 30.9 GB
  # with 3.6 GB in use draws a bar that is 88 percent empty, and the share of each kind
  # is then too small to read. The `Free` row below says how full the card is, which is
  # the other question and a number rather than a shape.
  #
  # The rows under the bar carry the numbers, because a kind of 1 percent is a few
  # pixels wide and no person can measure that.
  #
  # A kind has a colour and a row, so identity never rests on the colour alone.
  #
  # **The bar is 24 pixels and it used to be 12.** `recess` carries a 3 pixel border on
  # each side, so half of a 12 pixel bar was its own edge and the colour inside it was a
  # 6 pixel line. The border is the grammar of this style and it is not going anywhere,
  # so the bar grew to leave room for it.
  #
  # **The gaps between the segments are ink, and they used to be the surface.** Two
  # pixels of pale cream between each pair read as tiles laid on a bench rather than one
  # bar divided, which is a thing a person asks about rather than reads. In the ink they
  # are the same line as the border around them, and the bar reads as one object.
  defp usage_bar(assigns) do
    ~H"""
    <div :if={@used_bytes > 0} id="storage-usage" class="mb-4">
      <div
        class="recess flex h-6 gap-0.5 overflow-hidden"
        style="background: var(--color-ink)"
        aria-hidden="true"
      >
        <div
          :for={kind <- @usage}
          class="min-w-[3px]"
          style={"width: #{share(kind.bytes, @used_bytes)}%; background: #{colour(kind.key)}"}
        >
        </div>
      </div>

      <ul class="mt-3 space-y-1 text-sm">
        <li :for={kind <- @usage} id={"usage-#{kind.key}"} class="flex items-center gap-2">
          <span class="size-2.5 shrink-0 rounded-sm" style={"background: #{colour(kind.key)}"}>
          </span>
          <span class="text-ink-dim">{kind.label}</span>
          <span class="numerals ml-auto text-ink-faint">{size(kind.bytes)}</span>
        </li>
      </ul>
    </div>
    """
  end

  # **A colour follows the kind, and never the size of it.** A person who removed the
  # episodes of one source must not find that every other colour moved.
  # `PiFi.Device.Storage.Usage` returns the kinds in a fixed order, and this map keeps
  # one colour for each key of it.
  #
  # **Measured with CIEDE2000, for every pair and not only the pairs that touch.** The
  # bar is one row and the legend under it is another, and a person comparing two rows
  # of the legend is comparing colours that never met on the bar. The worst pair here
  # stands at 14.5 and the median at 30.8, across normal vision, deuteranopia and
  # protanopia, simulated with the Viénot transform. Every colour stands at 26 or more
  # from the surface in both schemes.
  #
  # **The set before this one had a pair at 4.** Jellyfin's orange and the gold of the
  # database are the same yellow-brown to a deuteranope, which is half the population
  # that cannot tell red from green. It also gave Plex no colour at all, so Plex and
  # `other` drew the same grey and a person could not tell which was which — the
  # complaint that started this.
  #
  # **Three of the five are unchanged**, because the blue, the orange and the green
  # were never the problem. Plex takes a deep blue and the database takes a brick red,
  # and those two were chosen by searching Lab space for the pair that maximises the
  # smallest difference against the three that stay.
  #
  # **Five is the ceiling and a sixth is not available.** A search of 253 candidates
  # found nothing that clears the others by a useful margin once blue, orange, green
  # and grey are spoken for. A new source therefore takes the grey below, and the label
  # of its row is what says which source it is.
  #
  # **`other` is grey on purpose.** It is the fold of everything that no kind names, so
  # it must not read as a kind of its own.
  @colours %{
    "podcasts" => "#3987e5",
    "jellyfin" => "#d95926",
    "plex" => "#17629c",
    "artwork" => "#199e70",
    "database" => "#a23d39",
    "other" => "#60636a"
  }

  @unnamed_colour "#60636a"

  defp colour(key), do: Map.get(@colours, key, @unnamed_colour)

  # A kind of a few bytes still draws a row, and the bar gives it 3 pixels so a person
  # sees that it is there. The number in the row is what says how much it is.
  defp share(bytes, used), do: Float.round(bytes * 100 / used, 3)

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:back, :string, required: true)
  slot(:inner_block, required: true)

  defp section(assigns) do
    ~H"""
    <div id={@id} class="glass sheen rounded-xl p-4">
      <div class="mb-3 flex items-center gap-2">
        <.link navigate={@back} id="back" aria-label="Back" class="control rounded-lg p-1.5">
          <.icon name="ph-caret-left" class="size-4" />
        </.link>
        <h2 class="label text-ink">{@title}</h2>
      </div>

      {render_slot(@inner_block)}
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:to, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  defp row(assigns) do
    ~H"""
    <.link navigate={@to} id={@id} class="flex items-center gap-3 p-4">
      <.icon name={@icon} class="size-6 shrink-0 text-ink" />

      <span class="min-w-0 grow">
        <span class="display block truncate text-ink">{@title}</span>
        <span class="block truncate text-sm text-ink-dim">{render_slot(@inner_block)}</span>
      </span>

      <.icon name="ph-caret-right" class="size-5 shrink-0 text-ink" />
    </.link>
    """
  end

  attr(:device, :map, required: true)
  attr(:index, :integer, required: true)
  attr(:in_use?, :boolean, required: true)
  attr(:by_default?, :boolean, required: true)

  # The whole row is the control, so a person chooses a card by touching its name.
  # The row of the card in use is dead, because `select_output` starts the stream
  # again and a person who touches the card that already plays asks for nothing.
  defp output_device(assigns) do
    ~H"""
    <button
      type="button"
      id={"select-output-#{@index}"}
      phx-click="select_output"
      phx-value-id={@device.id}
      disabled={@in_use? and not @by_default?}
      aria-pressed={to_string(@in_use?)}
      class={[
        "flex w-full items-center gap-3 py-3 text-left first:pt-2 last:pb-2",
        !(@in_use? and not @by_default?) && "cursor-pointer"
      ]}
    >
      <span class={[
        "flex size-5 shrink-0 items-center justify-center rounded-full",
        if(@in_use?,
          do: "bg-accent/15 shadow-[inset_0_0_0_1px_var(--color-accent)]",
          else: "shadow-[inset_0_0_0_1px_var(--color-edge)]"
        )
      ]}>
        <span :if={@in_use?} class="size-2 rounded-full bg-accent" />
      </span>

      <span class="min-w-0 grow">
        <span class={["block truncate", if(@in_use?, do: "text-accent", else: "text-ink")]}>
          {@device.title}
        </span>
        <span class="numerals block truncate text-xs text-ink-faint">{@device.id}</span>
      </span>

      <span :if={@in_use?} id={"selected-#{@index}"} class="flex shrink-0 items-center gap-2">
        <span :if={@by_default?} class="text-xs uppercase tracking-widest text-ink-faint">
          By default
        </span>
        <.icon name="ph-speaker-high" class="size-5 text-accent" />
        <span class="sr-only">Enabled</span>
      </span>
    </button>
    """
  end

  attr(:source, :map, required: true)

  defp use_control(assigns) do
    ~H"""
    <button
      type="button"
      id={"enable-source-#{@source.slug}"}
      phx-click="enable_source"
      phx-value-slug={@source.slug}
      phx-value-enabled={to_string(not @source.enabled?)}
      class={[
        "control shrink-0 rounded-lg px-3 py-1.5 text-xs",
        @source.enabled? && "control-on"
      ]}
    >
      {if @source.enabled?, do: "Disable", else: "Enable"}
    </button>
    """
  end

  # **The browser sends the file to a temporary path, and this reads it there.**
  # `PiFi.Artwork` writes the bytes to the cache, so the picture reaches the disk one
  # time and the temporary file goes when this function answers.
  @sobelow_skip ["Traversal.FileModule"]
  defp splash_progress(:splash, %{done?: true} = entry, socket) do
    bytes = consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

    {:noreply, splash_answer(socket, Identity.put_splash(bytes))}
  end

  defp splash_progress(:splash, _entry, socket), do: {:noreply, socket}

  defp splash_answer(socket, :ok) do
    socket |> put_flash(:info, "Each screen shows that picture now.") |> refresh()
  end

  defp splash_answer(socket, {:error, message}), do: put_flash(socket, :error, message)

  defp upload_message(:too_large), do: "That file is larger than 4096 KB."
  defp upload_message(:not_accepted), do: "That file isn't a JPEG or a PNG."
  defp upload_message(:too_many_files), do: "Choose one picture."
  defp upload_message(error), do: "That upload failed: #{inspect(error)}"

  defp title(socket), do: PiFiWeb.Shell.put_page(socket, "Settings")

  # A source reads its own current values, and a description of one carries a count
  # or a state, so both come again after each change. See `PiFi.Source`.
  defp load_source(socket, module) do
    fields = Source.settings(module)

    assign(socket, :source, %{
      module: module,
      title: module.title(),
      icon: module.icon(),
      slug: Source.slug(module),
      enabled?: Source.enabled?(module),
      description: Source.description(module),
      fields: fields,
      actions: Source.settings_actions(module),
      jobs: sync_jobs(module),
      form: to_form(Map.new(fields, &{&1.key, &1.value || ""}), as: :source)
    })
  end

  # The top row of the faceplate draws the sources in use, and a change here must
  # reach it at once. See `PiFiWeb.Shell`.
  defp reload(socket, module) do
    socket = PiFiWeb.Shell.assign_sources(socket)

    case socket.assigns.live_action do
      :source -> socket |> refresh() |> load_source(module)
      _other -> refresh(socket)
    end
  end

  # **It is not supervised and it is not linked, and both are on purpose.** Linked would
  # take this page down with a pairing that raised, and supervised would mean another
  # child in `PiFi.Application` for a button. What matters is that the page hears back,
  # so the work is wrapped and an answer is sent whatever happens — a page that sat on
  # "Working…" for ever would be worse than either.
  defp bluetooth_task(socket, path, outcome, work) do
    parent = self()

    Task.start(fn ->
      result =
        try do
          work.()
        rescue
          exception -> {:error, exception}
        catch
          :exit, reason -> {:error, reason}
        end

      send(parent, {:bluetooth_done, outcome, result})
    end)

    assign(socket, :bluetooth_busy, path)
  end

  defp bluetooth_said(socket, :paired, :ok), do: put_flash(socket, :info, "Paired.")

  # **A headset that has gone to sleep is the commonest failure, by a distance.** Saying
  # so is more use than the name of a D-Bus error.
  defp bluetooth_said(socket, :paired, {:error, _reason}) do
    put_flash(socket, :error, "Could not pair. Check it is still in pairing mode and try again.")
  end

  defp bluetooth_said(socket, :forgotten, :ok), do: put_flash(socket, :info, "Forgotten.")

  defp bluetooth_said(socket, :forgotten, {:error, _reason}) do
    put_flash(socket, :error, "Could not forget that one.")
  end

  defp bluetooth_summary(false, _devices), do: "Off"

  defp bluetooth_summary(true, devices) do
    case Enum.count(devices, & &1.paired?) do
      0 -> "On, nothing paired"
      1 -> "On, 1 device"
      count -> "On, #{count} devices"
    end
  end

  # **A path is an object path of D-Bus and not a thing to put in an identifier.**
  # `/org/bluez/hci0/dev_70_BF_92_04_AC_5A` in an `id` is a selector that no test can
  # write without escaping every slash and colon in it.
  defp bluetooth_slug(%{address: address}), do: String.replace(address, ":", "-")

  defp bluetooth_state(%{path: path}, busy) when path == busy, do: "Working…"
  defp bluetooth_state(%{connected?: true}, _busy), do: "Connected"
  defp bluetooth_state(%{paired?: true}, _busy), do: "Paired"
  defp bluetooth_state(_device, _busy), do: "Not paired"

  defp bluetooth_devices do
    case Bluetooth.Devices.list() do
      {:ok, devices} -> devices
      {:error, _reason} -> []
    end
  end

  # A person who opens the page has had no event yet, and a person who changed
  # something wants to see the answer of that change now.
  defp refresh(socket) do
    name = Identity.name()

    socket
    |> assign(:device_name, name)
    |> assign(:device_slug, Identity.slug(name))
    |> assign(:device_form, to_form(%{"name" => name}, as: :device))
    |> assign(:splash_path, Identity.splash_path())
    |> assign(:splash_form, to_form(%{}, as: :splash))
    |> assign(:profiles, Hardware.profiles())
    |> assign(:profile, Hardware.chosen())
    |> assign(:output, PiFi.Playback.output!())
    |> assign(:interfaces, Device.network!())
    |> assign(:storage, Device.storage!())
    |> assign(:upgrade, Device.upgrade!())
    |> assign(:home_assistant?, HomeAssistant.enabled?())
    |> assign(:airplay?, AirPlay.enabled?())
    |> assign(:bluetooth?, Bluetooth.enabled?())
    |> assign(:bluetooth_adapter?, Bluetooth.adapter?())
    |> assign(:bluetooth_devices, bluetooth_devices())
    |> assign_new(:bluetooth_scanning?, fn -> false end)
    |> assign_new(:bluetooth_busy, fn -> nil end)
    |> assign(:source_list, source_list())
    |> assign(:peripheral_list, peripheral_list())
    |> assign(:standby_minutes, PiFi.Playback.standby_minutes!())
    |> assign(:crossfade_seconds, PiFi.Playback.crossfade_seconds!())
    |> assign(:clock, Device.clock!())
    |> assign(:screen_blank_seconds, PiFi.Playback.screen_blank_seconds!())
    |> assign(:screen?, Peripheral.any_screen?())
    |> assign(:switch_off?, SwitchOff.enabled?())
    |> assign(:volume, PiFi.Playback.volume!())
    |> assign_usage()
  end

  # **The storage page reads this, and no other page does.** It sums the cache and it
  # reads every item whose audio the card keeps, where `PiFi.Device.storage!/0` runs `df` and
  # nothing else, so a page that draws no bar must not pay for one.
  defp assign_usage(%{assigns: %{live_action: :storage}} = socket),
    do: assign(socket, :usage, Device.storage_usage!())

  defp assign_usage(socket), do: socket

  defp firmware_summary(%{state: :installing, percent: percent}), do: "Installing, #{percent}%"
  defp firmware_summary(%{available: nil, running: running}), do: "#{running}, up to date"
  defp firmware_summary(%{available: available}), do: "Version #{available} is ready"

  defp check_message(%{available: nil}), do: "This is the newest firmware."
  defp check_message(%{available: version}), do: "Version #{version} is ready to install."

  defp checked_text(nil), do: "Not yet"
  defp checked_text(at), do: local(at, "%d %B, %H:%M")

  # The periods that a person can pick. A free number would need a check of its own on
  # this page, and no person of a stereo wants 37 minutes.
  # The period of a job sits in the section of the source that the job belongs to, and
  # this page names no job of its own. Reading the trending list means nothing without
  # podcasts. See `PiFi.AutoSync.jobs_for/1`.
  defp sync_jobs(source) do
    Enum.map(AutoSync.jobs_for(source), fn job ->
      job
      |> Map.take([:key, :title, :description])
      |> Map.put(:hours, AutoSync.hours(job.key))
      |> Map.put(:last_run, AutoSync.last_run(job.key))
    end)
  end

  # The hours that a person can choose for one job of `PiFi.AutoSync`. A station list
  # moves slowly and a feed of a podcast moves each day, so the list reaches a week.
  defp sync_periods, do: [0, 1, 6, 12, 24, 72, 168]

  # **A time that a person reads is in their place and not in Greenwich.** A device that
  # nobody told keeps the `UTC` after it, so they can see that it is showing the time it
  # knows rather than the time where they are. See `PiFi.Device.Timezone`.
  defp local(at, format) do
    Calendar.strftime(Timezone.at(at), format) <> Timezone.suffix(Timezone.get())
  end

  defp timezone_summary(%{default?: true}), do: "Not set, so times read in UTC"
  defp timezone_summary(%{timezone: zone}), do: zone

  defp timezone_flash(zone), do: "PiFi is in #{zone} now."

  defp crossfade_summary(0), do: "Off"
  defp crossfade_summary(seconds), do: crossfade_title(seconds)

  defp crossfade_title(0), do: "Off"
  defp crossfade_title(1), do: "1 second"
  defp crossfade_title(seconds), do: "#{seconds} seconds"

  defp crossfade_flash("0"), do: "One track stops before the next one starts."

  defp crossfade_flash(seconds),
    do: "Tracks cross over for #{String.downcase(crossfade_title(String.to_integer(seconds)))}."

  defp sync_period_title(0), do: "Never"
  defp sync_period_title(1), do: "Hourly"
  defp sync_period_title(24), do: "Daily"
  defp sync_period_title(72), do: "Every 3 days"
  defp sync_period_title(168), do: "Weekly"
  defp sync_period_title(hours), do: "Every #{hours} hours"

  defp sync_flash(key, "0"), do: "#{sync_title(key)} does not sync by itself now."

  defp sync_flash(key, hours),
    do: "#{sync_title(key)}: #{String.downcase(sync_period_title(String.to_integer(hours)))}."

  defp sync_title(key) do
    case Enum.find(AutoSync.jobs(), &(&1.key == key)) do
      nil -> key
      job -> job.title
    end
  end

  defp last_run_title(nil), do: "Hasn't run yet."
  defp last_run_title(at), do: "It last ran on #{local(at, "%d %B at %H:%M")}."

  defp periods, do: [0, 5, 10, 15, 20, 30, 45, 60, 90, 120]

  defp period_title(0), do: "Never"
  defp period_title(60), do: "After 1 hour"
  defp period_title(90), do: "After 1 hour and 30 minutes"
  defp period_title(120), do: "After 2 hours"
  defp period_title(minutes), do: "After #{minutes} minutes"

  defp standby_summary(0), do: "Stays awake"
  defp standby_summary(minutes), do: period_title(minutes)

  # The periods that a person can pick for the screen. A device that runs on a battery
  # wants a short one, and a device on the mains wants none at all.
  defp blank_periods, do: [0, 10, 15, 30, 45, 60, 120, 300]

  defp blank_title(0), do: "Never"
  defp blank_title(60), do: "After 1 minute"
  defp blank_title(120), do: "After 2 minutes"
  defp blank_title(300), do: "After 5 minutes"
  defp blank_title(seconds), do: "After #{seconds} seconds"

  defp screen_summary(0), do: "The screen stays lit"
  defp screen_summary(seconds), do: blank_title(seconds)

  defp switch_off_flash(true),
    do: "PiFi stops its background work in standby and says when it's safe to switch off."

  defp switch_off_flash(false), do: "PiFi keeps working in standby."

  defp volume_flash(true), do: "PiFi sets the volume on the sound card."

  defp volume_flash(false),
    do: "The sound card plays at full volume. Use your amplifier instead."

  defp standby_flash("0"), do: "PiFi stays awake."
  defp standby_flash(minutes), do: "PiFi enters standby after #{minutes} minutes of quiet."

  defp screen_flash("0"), do: "The screen stays lit."

  defp screen_flash(seconds),
    do: "The screen goes dark after #{seconds} seconds."

  # `:sources` belongs to `PiFiWeb.Shell`, and the top row of the faceplate draws
  # it. That list names the sources in use, and this one names every source and the
  # state of it, so the two cannot share one name.
  defp source_list do
    Enum.map(Source.all(), fn module ->
      %{
        module: module,
        title: module.title(),
        icon: module.icon(),
        slug: Source.slug(module),
        enabled?: Source.enabled?(module)
      }
    end)
  end

  # `enabled?` is what a person asked for, and `running?` is what the hardware gave.
  # The two are different when a person turns a screen on and the screen is not wired,
  # and a page that showed one of them would tell them the wrong thing.
  defp peripheral_list do
    Enum.map(Peripheral.all(), fn {module, _options} ->
      %{
        module: module,
        title: module.title(),
        slug: Peripheral.slug(module),
        enabled?: Peripheral.enabled?(module),
        running?: Peripheral.running?(module)
      }
    end)
  end

  defp peripheral_state(%{enabled?: false}), do: "Disabled"
  defp peripheral_state(%{running?: true}), do: "Enabled"
  defp peripheral_state(_peripheral), do: "Enabled, but it failed to start"

  defp peripheral_in_use(module) do
    if Peripheral.enabled?(module),
      do: "#{module.title()} is in use.",
      else: "#{module.title()} is out of use."
  end

  defp peripherals_summary([]), do: "No peripherals are configured"

  defp peripherals_summary(peripherals) do
    "#{Enum.count(peripherals, & &1.running?)} of #{length(peripherals)} running"
  end

  # A job removes what the cache held for a source that goes out of use, and it takes
  # a while for a library. The message therefore says that the work started, and not
  # that it finished. See `PiFi.Playback.RemoveSourceCache`.
  defp in_use(module) do
    if Source.enabled?(module),
      do: "#{module.title()} is in use.",
      else: "#{module.title()} is out of use. The device is removing what it kept for it."
  end

  defp state(true), do: "Enabled"
  defp state(false), do: "Disabled"

  # A write-only field shows nothing that the device keeps, so the control says
  # what a person must type instead.
  defp placeholder(%{write_only?: true, title: title}), do: title
  defp placeholder(_field), do: nil

  defp output_summary(%{devices: []}), do: "No sound card found"

  defp output_summary(%{devices: devices, selected: selected, in_use: in_use}) do
    title =
      case Enum.find(devices, &(&1.id == in_use)) do
        nil -> in_use
        device -> device.title
      end

    if is_nil(selected), do: "#{title}, by default", else: title
  end

  # A DAC can leave the machine. The player then uses the first card, so a person
  # must read why the card that they chose is not the one that plays.
  defp absent_choice?(%{selected: nil}), do: false

  defp absent_choice?(%{devices: devices, selected: selected}) do
    not Enum.any?(devices, &(&1.id == selected))
  end

  # **A source says that a paragraph is a warning, and this page chooses the colour.**
  # The licence question of Spotify is the one that matters: a person deciding whether
  # to turn it on must be able to see which paragraph is the risk. See
  # `t:PiFi.Source.paragraph/0`.
  defp paragraph_class({:warning, _text}), do: "text-danger"
  defp paragraph_class(_text), do: "text-ink-dim"

  defp paragraph_text({:warning, text}), do: text
  defp paragraph_text(text), do: text

  defp sources_summary(sources) do
    "#{Enum.count(sources, & &1.enabled?)} of #{length(sources)} enabled"
  end

  defp network_summary([]), do: "No network interfaces found"

  defp network_summary(interfaces) do
    Enum.map_join(interfaces, ", ", &connection(&1.connection))
  end

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
