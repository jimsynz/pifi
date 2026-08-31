defmodule MyHiFiWeb.SettingsLive do
  @moduledoc """
  What the device holds, and what a person can change.

  The page is a menu, and each row of it opens one section. The address names the
  section, so a person can keep the address of one and the back control of the
  browser moves out of it.

      /settings                        the menu
      /settings/output                 the sound card
      /settings/sources                the sources, and which ones are in use
      /settings/sources/internet-radio one source
      /settings/peripherals            the screens and the controls of the board
      /settings/network                a report
      /settings/storage                a report

  **This page holds no knowledge of any source.** A source names its own settings
  with `c:MyHiFi.Source.settings/0`, and its own controls with
  `c:MyHiFi.Source.settings_actions/0`. The countries of the station list belong to
  internet radio, and the key of the Podcast Index belongs to podcasts. A new
  source therefore reaches this page without a change here.

  The page never sends the secret of an index back to a browser. A source marks
  such a field `write_only?`, and it then gives no value for it.

  It holds no knowledge of any peripheral either. A peripheral names itself with
  `c:MyHiFi.Peripheral.title/0`, and this page draws that name and one control. A
  peripheral is out of use until a person says that the part is wired, because the same
  image runs on a board with a screen and on a board with none. See
  `MyHiFi.Peripheral`.

  The network state and the storage state are reports, and a person changes neither
  one here. The Wi-Fi details belong to the setup wizard. See `MyHiFi.Setup`.

  **The reports arrive, and this page asks for none of them.** A DAC arrives, Wi-Fi
  connects, and a download fills the card, so the three reports change without a
  person. This page read all three every five seconds before, which was eleven queries
  each time for an answer that almost never moved. `MyHiFi.Device.Monitor` owns the
  three sources of truth now and publishes on the `:device` topic. This page reads once
  when a person opens it, because no event has arrived yet, and after that it draws what
  it is told.
  """

  use MyHiFiWeb, :live_view

  alias MyHiFi.Device
  alias MyHiFi.Event
  alias MyHiFi.Event.Device, as: Events
  alias MyHiFi.Hardware
  alias MyHiFi.Peripheral
  alias MyHiFi.Source

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Event.subscribe(:device)

    {:ok, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"source" => slug}, _uri, socket) do
    case Source.from_slug(slug) do
      {:ok, module} -> {:noreply, socket |> title() |> load_source(module)}
      {:error, :not_a_source} -> {:noreply, push_navigate(socket, to: ~p"/settings/sources")}
    end
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
  def handle_info(%Events.OutputChanged{} = event, socket) do
    {:noreply, assign(socket, :output, Map.take(event, [:devices, :selected, :in_use]))}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.StorageChanged{} = event, socket) do
    fields = [:path, :total_bytes, :free_bytes, :used_bytes, :database_bytes, :full?]

    {:noreply, assign(socket, :storage, Map.take(event, fields))}
  end

  # The player publishes on this topic as well, and no report of this page changes with
  # it.
  @impl Phoenix.LiveView
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("enable_source", %{"slug" => slug, "enabled" => enabled}, socket) do
    with {:ok, module} <- Source.from_slug(slug),
         {:ok, :ok} <- MyHiFi.Playback.enable_source(module, enabled == "true") do
      {:noreply, socket |> put_flash(:info, in_use(module)) |> reload(module)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not do that: #{inspect(reason)}")}
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
         |> put_flash(:error, "That did not start: #{inspect(reason)}")
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
         |> put_flash(:info, "The device restarts to use that.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "That did not work: #{inspect(reason)}")}
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
  def handle_event("select_output", %{"id" => id}, socket) do
    case MyHiFi.Playback.select_output(id) do
      {:ok, :ok} ->
        {:noreply, socket |> put_flash(:info, "The output device is #{id}.") |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not do that: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :menu} = assigns) do
    ~H"""
    <div id="settings" class="glass sheen divide-y divide-edge rounded-xl">
      <.row id="output-row" to={~p"/settings/output"} icon="hero-speaker-wave" title="Output device">
        {output_summary(@output)}
      </.row>

      <.row id="sources-row" to={~p"/settings/sources"} icon="hero-queue-list" title="Sources">
        {sources_summary(@source_list)}
      </.row>

      <.row
        id="peripherals-row"
        to={~p"/settings/peripherals"}
        icon="hero-cpu-chip"
        title="Peripherals"
      >
        {peripherals_summary(@peripheral_list)}
      </.row>

      <.row id="network-row" to={~p"/settings/network"} icon="hero-wifi" title="Network">
        {network_summary(@interfaces)}
      </.row>

      <.row
        id="storage-row"
        to={~p"/settings/storage"}
        icon="hero-circle-stack"
        title="Storage"
      >
        {size(@storage.free_bytes)} free of {size(@storage.total_bytes)}
      </.row>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :output} = assigns) do
    ~H"""
    <.section id="settings-output" title="Output device" back={~p"/settings"}>
      <p :if={@output.devices == []} id="no-output" class="text-sm text-ink-dim">
        No sound card is present.
      </p>

      <p :if={absent_choice?(@output)} id="absent-output" class="mb-3 text-sm text-ink-dim">
        The card that you chose is not present. The device uses the first one instead.
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

      <.link
        navigate={~p"/settings/output/hardware"}
        id="hardware-link"
        class="mt-4 flex items-center gap-2 border-t border-edge pt-4 text-sm text-ink-dim hover:text-accent"
      >
        <.icon name="hero-question-mark-circle" class="size-4 shrink-0" />
        Do you not see your audio device?
      </.link>
    </.section>
    """
  end

  # A DAC on the I2S pins answers to nothing until the bootloader loads an overlay for
  # it, so no list of cards holds one and no control of this page finds one. A person
  # names what they added instead. See `MyHiFi.Hardware`.
  @impl Phoenix.LiveView
  def render(%{live_action: :hardware} = assigns) do
    ~H"""
    <.section id="settings-hardware" title="Audio hardware" back={~p"/settings/output"}>
      <p class="mb-4 text-sm text-ink-dim">
        A DAC on the pins of the board needs a driver that starts before the rest of the
        firmware. Name what you added, and the device restarts to use it.
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
              name={if profile.id == @profile.id, do: "hero-check-circle-solid", else: "hero-circle-stack"}
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
        A source out of use leaves the top row, and it asks the network for nothing.
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

          <.icon name="hero-chevron-right" class="size-4 shrink-0 text-ink-faint" />
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

      <p :if={@source.fields == [] and @source.actions == []} id="no-source-settings" class="text-sm text-ink-dim">
        {@source.title} holds nothing else to change.
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
    </.section>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :peripherals} = assigns) do
    ~H"""
    <.section id="settings-peripherals" title="Peripherals" back={~p"/settings"}>
      <p class="mb-3 text-sm text-ink-dim">
        This firmware runs on a board with a screen and on a board with none, so it
        cannot know what yours holds. Name the parts that you wired.
      </p>

      <p :if={@peripheral_list == []} id="no-peripherals" class="text-sm text-ink-dim">
        This firmware knows no peripheral.
      </p>

      <ul class="divide-y divide-edge">
        <li
          :for={peripheral <- @peripheral_list}
          id={"peripheral-row-#{peripheral.slug}"}
          class="flex items-center gap-3 py-2 first:pt-0 last:pb-0"
        >
          <.icon
            name="hero-cpu-chip"
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
            {if peripheral.enabled?, do: "Take out of use", else: "Put in use"}
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
    </.section>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :storage} = assigns) do
    ~H"""
    <.section id="settings-storage" title="Storage" back={~p"/settings"}>
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

      <p :if={@storage.full?} id="storage-warning" class="mt-3 text-sm text-red-300">
        This partition is nearly full.
      </p>
    </.section>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:back, :string, required: true)
  slot(:inner_block, required: true)

  defp section(assigns) do
    ~H"""
    <div id={@id} class="glass sheen rounded-xl p-4">
      <div class="mb-3 flex items-center gap-2">
        <.link navigate={@back} id="back" aria-label="Back" class="control rounded-lg p-1.5">
          <.icon name="hero-chevron-left" class="size-4" />
        </.link>
        <h2 class="text-xs uppercase tracking-[0.18em] text-ink-faint">{@title}</h2>
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
      <.icon name={@icon} class="size-5 shrink-0 text-ink-faint" />

      <span class="min-w-0 grow">
        <span class="block truncate text-ink">{@title}</span>
        <span class="block truncate text-sm text-ink-dim">{render_slot(@inner_block)}</span>
      </span>

      <.icon name="hero-chevron-right" class="size-4 shrink-0 text-ink-faint" />
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
        <.icon name="hero-speaker-wave" class="size-5 text-accent" />
        <span class="sr-only">In use</span>
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
      {if @source.enabled?, do: "Take out of use", else: "Put in use"}
    </button>
    """
  end

  defp title(socket), do: assign(socket, :page_title, "Settings")

  # A source reads its own current values, and a description of one holds a count
  # or a state, so both come again after each change. See `MyHiFi.Source`.
  defp load_source(socket, module) do
    fields = Source.settings(module)

    assign(socket, :source, %{
      module: module,
      title: module.title(),
      icon: module.icon(),
      slug: Source.slug(module),
      enabled?: Source.enabled?(module),
      fields: fields,
      actions: Source.settings_actions(module),
      form: to_form(Map.new(fields, &{&1.key, &1.value || ""}), as: :source)
    })
  end

  # The top row of the faceplate holds the sources in use, and a change here must
  # reach it at once. See `MyHiFiWeb.Shell`.
  defp reload(socket, module) do
    socket = MyHiFiWeb.Shell.assign_sources(socket)

    case socket.assigns.live_action do
      :source -> socket |> refresh() |> load_source(module)
      _other -> refresh(socket)
    end
  end

  # A person who opens the page has had no event yet, and a person who changed
  # something wants to see the answer of that change now.
  defp refresh(socket) do
    socket
    |> assign(:profiles, Hardware.profiles())
    |> assign(:profile, Hardware.chosen())
    |> assign(:output, MyHiFi.Playback.output!())
    |> assign(:interfaces, Device.network!())
    |> assign(:storage, Device.storage!())
    |> assign(:source_list, source_list())
    |> assign(:peripheral_list, peripheral_list())
  end

  # `:sources` belongs to `MyHiFiWeb.Shell`, and the top row of the faceplate draws
  # it. That list holds the sources in use, and this one holds every source and the
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

  defp peripheral_state(%{enabled?: false}), do: "Out of use"
  defp peripheral_state(%{running?: true}), do: "In use"
  defp peripheral_state(_peripheral), do: "In use, and it did not start"

  defp peripheral_in_use(module) do
    if Peripheral.enabled?(module),
      do: "#{module.title()} is in use.",
      else: "#{module.title()} is out of use."
  end

  defp peripherals_summary([]), do: "This firmware knows none"

  defp peripherals_summary(peripherals) do
    "#{Enum.count(peripherals, & &1.running?)} of #{length(peripherals)} running"
  end

  defp in_use(module) do
    if Source.enabled?(module),
      do: "#{module.title()} is in use.",
      else: "#{module.title()} is out of use."
  end

  defp state(true), do: "In use"
  defp state(false), do: "Out of use"

  # A write-only field shows nothing that the device holds, so the control says
  # what a person must type instead.
  defp placeholder(%{write_only?: true, title: title}), do: title
  defp placeholder(_field), do: nil

  defp output_summary(%{devices: []}), do: "No sound card is present"

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

  defp sources_summary(sources) do
    "#{Enum.count(sources, & &1.enabled?)} of #{length(sources)} in use"
  end

  defp network_summary([]), do: "The network state comes from the device"

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
