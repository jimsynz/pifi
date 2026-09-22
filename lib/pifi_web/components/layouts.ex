defmodule PiFiWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  """
  use PiFiWeb, :html

  embed_templates("layouts/*")

  @doc """
  One control of the top row of the faceplate.

  A device in standby offers one control, and the control is the power button. Each
  control of this row is therefore dead while the device sleeps. It keeps its place
  and its name, so the faceplate does not move when the device wakes.

  **The row holds two kinds of control, and `quiet?` is which.** A source is what a
  person switches between, and it keeps the box: border, panel and offset shadow.
  Search, playlists, the queue, history and settings are how they get around, and they
  are drawn as marks alone. Nine boxes of one weight gave the eye nothing to rest on
  and ran the row out of width as soon as a fourth source arrived. See `control-quiet`
  in `assets/css/app.css`.
  """
  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :label, :string, default: nil
  attr :current?, :boolean, default: false
  attr :quiet?, :boolean, default: false
  attr :standby?, :boolean, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def faceplate_control(%{standby?: true} = assigns) do
    ~H"""
    <span
      id={@id}
      aria-label={@label}
      aria-disabled="true"
      class={[base(@quiet?), "cursor-default opacity-45", @class]}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  def faceplate_control(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      aria-label={@label}
      aria-current={@current? && "page"}
      class={[base(@quiet?), @current? && current(@quiet?), @class]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp base(true), do: "control-quiet"
  defp base(false), do: "control"

  defp current(true), do: "control-quiet-on"
  defp current(false), do: "control-on"
end
