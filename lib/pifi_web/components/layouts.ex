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
  """
  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :label, :string, default: nil
  attr :current?, :boolean, default: false
  attr :standby?, :boolean, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def faceplate_control(%{standby?: true} = assigns) do
    ~H"""
    <span
      id={@id}
      aria-label={@label}
      aria-disabled="true"
      class={["control cursor-default opacity-45", @class]}
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
      class={["control", @current? && "control-on", @class]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
