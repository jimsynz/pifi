defmodule MyHiFiWeb.CinderTheme do
  @moduledoc """
  The faceplate style for `Cinder.collection`.

  The web interface of this firmware looks like the front of a stereo component: a dark
  brushed fascia, recessed panels, and one accent colour that follows the artwork of the
  track. `assets/css/app.css` holds that vocabulary as Tailwind utilities, and this
  module gives it to Cinder. The utilities are `control`, `control-on`, `recess`,
  `glass`, `sheen` and `numerals`, and the colours are `shell`, `panel`, `edge`, `ink`
  and `accent`.

  `config/config.exs` names this module as `default_theme`, so every collection of this
  firmware gets it and no page names a theme.

  ## What this theme covers

  It covers what the browse page draws: the list layout, the filters, the sort controls,
  the pagination, and the empty, loading and error states. It leaves the table layout,
  the grid layout, the selection controls and the bulk actions at the values that Cinder
  gives, because no page of this firmware draws one of those. A page that starts to draw
  one needs the keys for it here, or it gets a white card on a dark fascia.

  ## Tailwind must see this file

  `app.css` names `@source "../../lib/my_hi_fi_web"`, so a class in this module reaches
  the stylesheet. A theme outside that directory gives no CSS at all.
  """

  use Cinder.Theme

  # The filters and the sort share one panel above the list, so they read as one strip
  # of controls on the fascia. `container_class` stays empty, because the renderer puts
  # `relative` on that element by itself.
  set :controls_class, "glass mb-4 gap-3 rounded-xl p-3"

  # Filters. The header reads as a label of the fascia, in small capitals.
  set :filter_header_class, "mb-2 flex items-center justify-between gap-2"

  set :filter_title_class,
      "flex items-center gap-2 text-[0.65rem] uppercase tracking-[0.18em] text-ink-faint"

  set :filter_count_class, "rounded-full bg-accent/15 px-2 py-0.5 tracking-normal text-accent"

  set :filter_clear_all_class, "control rounded-lg px-2 py-1 text-xs"
  set :filter_inputs_class, "flex flex-col gap-2"

  # The label stands before the input, and not above it, so one filter takes one row.
  # `[&>div]:grow` reaches the group that holds the input, which is the second child of
  # this element and carries a class of its own from Cinder.
  set :filter_input_wrapper_class, "flex items-center gap-3 [&>div]:grow"

  # `min-w-28` holds this label and the label of the sort in one column. It is wide
  # enough for `Subscriptions`, which is the longest branch name of this firmware.
  set :filter_label_class,
      "min-w-28 shrink-0 text-[0.65rem] uppercase tracking-[0.18em] text-ink-faint"

  set :filter_text_input_class,
      "recess w-full rounded-lg border-0 px-3 py-2 text-sm text-ink placeholder:text-ink-faint focus:outline-none focus:ring-1 focus:ring-accent/60"

  # Cinder puts the magnifier inside the input, at the left of it, so the text needs room
  # to clear it.
  set :search_input_class,
      "recess w-full rounded-lg border-0 py-2 pl-9 pr-3 text-sm text-ink placeholder:text-ink-faint focus:outline-none focus:ring-1 focus:ring-accent/60"

  set :search_icon_class, "size-4 text-ink-faint"

  set :filter_clear_button_class,
      "ml-1 flex size-8 shrink-0 items-center justify-center rounded-full text-ink-faint hover:text-accent"

  # The control that chooses one of a list. Cinder draws a button and a panel below it,
  # and not a `select` of the browser, so the panel needs a background of its own and a
  # place above the rows.
  set :filter_select_container_class, "relative"

  set :filter_select_input_class,
      "recess w-full rounded-lg px-3 py-2 text-left text-sm text-ink"

  set :filter_select_placeholder_class, "text-ink-faint"
  set :filter_select_arrow_class, "ml-2 size-4 shrink-0 text-ink-faint"

  set :filter_select_dropdown_class,
      "glass absolute z-20 mt-1 w-full overflow-hidden rounded-lg p-1"

  set :filter_select_option_class, "rounded px-2 py-1.5 hover:bg-edge"
  set :filter_select_label_class, "text-sm text-ink"
  set :filter_select_empty_class, "px-2 py-1.5 text-sm text-ink-faint"

  # Sort. Each field is a control of the fascia, and the one in use lights up. A hairline
  # holds it apart from the filters above it.
  set :sort_container_class, "mt-3 border-t border-edge pt-3"
  set :sort_controls_class, "flex flex-wrap items-center gap-2"

  set :sort_controls_label_class,
      "min-w-28 shrink-0 text-[0.65rem] uppercase tracking-[0.18em] text-ink-faint"

  set :sort_buttons_class, "flex flex-wrap gap-1"
  set :sort_button_class, "control inline-flex items-center rounded-lg px-3 py-1.5 text-sm"
  set :sort_button_active_class, "control-on"
  set :sort_button_inactive_class, ""
  set :sort_indicator_class, "ml-1.5 inline-flex items-center align-baseline"

  # The list. Each row draws itself, so this holds the line between two rows and nothing
  # else.
  set :list_container_class, "divide-y divide-edge"
  set :list_item_class, "px-1 py-1.5 text-ink"
  set :list_item_clickable_class, "cursor-pointer rounded-lg transition-colors hover:bg-edge"

  # Pagination. The count reads as a meter, in the numerals of the fascia.
  set :pagination_wrapper_class, "mt-4 border-t border-edge pt-3"

  set :pagination_container_class, "flex flex-wrap items-center justify-between gap-3 text-sm"

  set :pagination_info_class, "numerals text-xs text-ink-faint"
  set :pagination_count_class, "text-ink-dim"
  set :pagination_nav_class, "flex items-center gap-1"
  set :pagination_button_class, "control rounded-lg px-3 py-1.5 text-sm"
  set :pagination_current_class, "control control-on rounded-lg px-3 py-1.5 text-sm"

  set :page_size_container_class,
      "flex items-center gap-2 text-[0.65rem] uppercase tracking-[0.18em] text-ink-faint"

  set :page_size_label_class, "shrink-0"
  set :page_size_dropdown_container_class, "relative"

  set :page_size_dropdown_class,
      "control rounded-lg px-2 py-1 text-sm normal-case tracking-normal"

  set :page_size_option_class,
      "block w-full px-3 py-1.5 text-left text-sm text-ink-dim hover:text-accent"

  set :page_size_selected_class, "text-accent"

  # A person waits, finds nothing, or meets a fault.
  set :loading_overlay_class, "py-6"

  set :loading_container_class, "flex items-center justify-center gap-2 text-sm text-ink-faint"

  set :loading_spinner_class, "size-4 motion-safe:animate-spin"
  set :loading_spinner_circle_class, "opacity-25"
  set :loading_spinner_path_class, "opacity-75"
  set :empty_class, "py-10 text-center text-sm text-ink-dim"
  set :error_container_class, "glass rounded-xl p-4 text-sm text-red-300"
  set :error_message_class, ""
end
