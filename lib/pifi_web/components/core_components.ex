defmodule PiFiWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  The components in this module use function components and can be used
  in both regular views and LiveView.

  The interface draws a dark faceplate. `assets/css/app.css` declares the tokens and
  the surfaces, and `assets/js/accent.js` reads `--color-accent` from the artwork
  that plays. A component therefore names `accent` and never a fixed colour.
  """

  use Phoenix.Component

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  # `PiFi.Source` names the icon of a source, and it names the icon of each
  # settings control of that source. Both names come from the same module, so both
  # are drawn here.
  #
  # A name of `brand-` is the mark of one service, and `assets/vendor/brand.js` draws
  # it in the way that `heroicons.js` draws the rest. Both become the mask of a span,
  # so a mark takes the accent colour of the interface like every other icon.
  # **A mark carries a licence and a trademark, and the two are not the same question.**
  # The Jellyfin mark is CC-BY-SA-4.0, and the Plex chevron carries no copyright at all,
  # because six straight sides are not a work. Each one is still the trademark of the
  # project that owns it, and this firmware draws it to name the service that a person
  # linked. That is the use that a trademark exists for.
  #
  # **The row hides its text below the `sm` breakpoint**, so on a telephone the mark
  # alone says which service a control opens. A wordmark is the wrong shape for that:
  # the Plex logo of 2022 is the word `plex`, and 20 pixels of it is a smudge beside a
  # label that already says Plex. `brand/plex.svg` is therefore the chevron.
  @source_icons %{
    airplay: "ph-airplay",
    cloud: "ph-cloud",
    jellyfin: "brand-jellyfin",
    library: "ph-stack",
    plex: "brand-plex",
    podcast: "ph-microphone",
    radio: "ph-broadcast",
    refresh: "ph-arrows-clockwise",
    remove: "ph-trash",
    spotify: "ph-spotify-logo"
  }

  @doc """
  Renders flash notices.

  A notice goes away when a person presses it, and `assets/js/flash.js` presses it for
  the person after a few seconds.

  ## Examples

      <.flash kind={:info} flash={@flash} />
  """
  attr(:id, :string, doc: "the optional id of flash container")
  attr(:flash, :map, default: %{}, doc: "the map of flash messages to display")
  attr(:title, :string, default: nil)
  attr(:kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup")
  attr(:rest, :global, doc: "the arbitrary HTML attributes to add to the flash container")

  slot(:inner_block, doc: "the optional inner block that renders the flash message")

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      role="alert"
      phx-hook="Flash"
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "##{@id}")}
      class={[
        "glass sheen pointer-events-auto cursor-pointer rounded-xl px-4 py-3 text-sm shadow-2xl",
        @kind == :info && "text-ink",
        @kind == :error && "text-danger border-danger/40"
      ]}
      {@rest}
    >
      <p :if={@title} class="font-medium">{@title}</p>
      <p>{msg}</p>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      class="pointer-events-none fixed inset-x-4 top-4 z-50 mx-auto flex max-w-sm flex-col gap-2 sm:left-auto sm:right-6"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customise the size and colours of the icons by setting
  width, height, and background colour classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="ph-x" />
      <.icon name="ph-arrows-clockwise" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr(:name, :string, required: true)
  attr(:class, :any, default: "size-4")

  def icon(%{name: "ph-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  # Cinder writes four of these, and this project owns none of those templates.
  # `assets/vendor/phosphor.js` draws them in the weight that the rest of the
  # interface holds.
  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  def icon(%{name: "brand-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  attr(:id, :any, default: nil)
  attr(:name, :any)
  attr(:label, :string, default: nil)
  attr(:value, :any)

  attr(:type, :string,
    default: "text",
    values: ~w(color date datetime-local email month number password
               range search tel text time url week)
  )

  attr(:field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"
  )

  attr(:errors, :list, default: [])
  attr(:class, :any, default: nil)

  attr(:rest, :global,
    include: ~w(accept autocomplete capture disabled form list max maxlength min minlength
              pattern placeholder readonly required size step)
  )

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(assigns) do
    ~H"""
    <div>
      <label :if={@label} class="mb-1 block text-xs uppercase tracking-widest text-ink-faint">
        {@label}
      </label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Form.normalize_value(@type, @value)}
        class={[field_class(), @class]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Renders an icon that `PiFi.Source` names.

  A source names its own icon, and each settings control of a source names one as
  well. `PiFi.Source` names the mark, and this module draws it. A name
  that this interface does not know gives a musical note, so a new source shows
  before this list learns it.
  """
  attr(:name, :atom, required: true)
  attr(:class, :any, default: "size-5")

  def source_icon(assigns) do
    assigns = assign(assigns, :hero, Map.get(@source_icons, assigns.name, "ph-music-note"))

    ~H"""
    <.icon name={@hero} class={@class} />
    """
  end

  @doc """
  Translates an error message.
  """
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp error(assigns) do
    ~H"""
    <p class="mt-1 text-sm text-danger">{render_slot(@inner_block)}</p>
    """
  end

  defp field_class do
    "recess w-full rounded-lg border border-edge px-3 py-2 text-ink placeholder:text-ink-faint " <>
      "outline-none focus:border-[color-mix(in_oklab,var(--color-accent)_50%,transparent)] " <>
      "focus:ring-1 focus:ring-[color-mix(in_oklab,var(--color-accent)_40%,transparent)]"
  end
end
