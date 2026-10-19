defmodule PiFi.Peripheral.ButtonJobs do
  @moduledoc """
  The jobs that a person gives the buttons of a board, on the settings page.

  Each button has four: a press and a hold with the menu closed, and a press and a hold
  with it open. Any job can go in any of the four, and "Nothing" turns one off. A board
  names its own defaults with `button_jobs/0`, which are what it did before a person
  changed anything. The PiTFT and the Pirate Audio both use this.

  **A button names its jobs, so `PiFi.DeviceUi` doesn't hold a table for each board.**
  The one that has no label reports its place; once a person has given it a job on the
  settings page, the job is its label. `pressed/3` builds the event with both jobs of
  the press, for the menu closed and for it open, and `PiFi.DeviceUi` picks between
  them, because it is the one part that knows for certain whether the menu is open when
  the press arrives.

  The settings are stored under the board's slug, such as
  `peripheral.pi-tft.button_2_hold`.
  """

  alias PiFi.Event.Input
  alias PiFi.Peripheral
  alias PiFi.Settings

  @jobs [
    {"standby", "Standby"},
    {"previous", "Previous track"},
    {"play_pause", "Play or pause"},
    {"next", "Next track"},
    {"volume_down", "Volume down"},
    {"volume_up", "Volume up"},
    {"open_menu", "Open the menu"},
    {"back", "Back"},
    {"row_up", "Row up"},
    {"select", "Open or play the row"},
    {"row_down", "Row down"},
    {"none", "Nothing"}
  ]

  @job_atoms Map.new(@jobs, fn {value, _label} -> {value, String.to_atom(value)} end)

  @slots [
    {:press, "press", "press"},
    {:hold, "hold", "hold"},
    {:menu_press, "menu_press", "press with the menu open"},
    {:menu_hold, "menu_hold", "hold with the menu open"}
  ]

  @typedoc "A job that a button can do. See `PiFi.Event.Input.ButtonPressed`."
  @type job ::
          :standby
          | :previous
          | :play_pause
          | :next
          | :volume_down
          | :volume_up
          | :open_menu
          | :back
          | :row_up
          | :select
          | :row_down
          | :none

  @typedoc "The four jobs of one button."
  @type jobs :: %{press: job(), hold: job(), menu_press: job(), menu_hold: job()}

  @doc "The settings fields of a board's buttons: four for each one."
  @spec settings(module()) :: [PiFi.Settings.field()]
  def settings(board) do
    for {defaults, button} <- Enum.with_index(board.button_jobs(), 1),
        {slot, key, words} <- @slots do
      %{
        key: field_key(button, key),
        title: "Button #{button}, #{words}",
        description: nil,
        link: nil,
        type: :select,
        options: @jobs,
        value: Atom.to_string(stored(board, button, slot, defaults[slot])),
        write_only?: false
      }
    end
  end

  @doc "Keep the jobs that a person chose. Each value must be one of the jobs."
  @spec put_settings(module(), %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, String.t()}
  def put_settings(board, values) do
    keys = Enum.map(settings(board), & &1.key)
    chosen = Map.take(values, keys)

    if Enum.all?(chosen, fn {_key, value} -> List.keymember?(@jobs, value, 0) end) do
      Enum.each(chosen, fn {key, value} -> Settings.put!(setting_key(board, key), value) end)
      {:ok, "Saved the buttons."}
    else
      {:error, "That isn't a job a button can do."}
    end
  end

  @doc """
  The event of a press of `button` on `board`, with the jobs a person gave it.
  `hold` is `:short` for a press and `:long` for a hold.
  """
  @spec pressed(module(), pos_integer(), :short | :long) :: Input.ButtonPressed.t()
  def pressed(board, button, hold) do
    defaults = Enum.at(board.button_jobs(), button - 1, %{})
    {closed, open} = if hold == :long, do: {:hold, :menu_hold}, else: {:press, :menu_press}

    %Input.ButtonPressed{
      peripheral: board,
      button: button,
      hold: hold,
      function: stored(board, button, closed, Map.get(defaults, closed, :none)),
      menu_function: stored(board, button, open, Map.get(defaults, open, :none))
    }
  end

  # A value that is no longer a job, such as one a later version dropped, reads as the
  # board's default rather than leave the button doing something unknown.
  defp stored(board, button, slot, default) do
    {^slot, key, _words} = List.keyfind(@slots, slot, 0)

    with {:ok, %{value: value}} <- Settings.fetch(setting_key(board, field_key(button, key))),
         {:ok, job} <- Map.fetch(@job_atoms, value) do
      job
    else
      _unset -> default
    end
  end

  defp field_key(button, key), do: "button_#{button}_#{key}"

  defp setting_key(board, key), do: "peripheral." <> Peripheral.slug(board) <> "." <> key
end
