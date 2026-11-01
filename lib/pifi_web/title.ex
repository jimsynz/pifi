defmodule PiFiWeb.Title do
  @moduledoc """
  Composes the browser title from the device name, page, and playback state.

  The current track takes precedence over the page name; standby is shown when the
  device is not playing.
  """

  @doc """
  Compose a title from the device name, page name, and player state.

  `page` may be `nil` when the current page has no name.

      iex> PiFiWeb.Title.compose("Kitchen", "Plex", %{playing?: false, paused?: false, standby?: false})
      "Kitchen — Plex"

      iex> PiFiWeb.Title.compose("Kitchen", nil, %{playing?: false, paused?: false, standby?: false})
      "Kitchen"

      iex> PiFiWeb.Title.compose("Kitchen", "Plex", %{playing?: false, paused?: false, standby?: true})
      "Kitchen — Standby"

  """
  @spec compose(String.t(), String.t() | nil, map()) :: String.t()
  def compose(device, page, state) do
    case describe(state) do
      nil -> join(device, page)
      description -> join(device, description)
    end
  end

  defp join(device, nil), do: device
  defp join(device, ""), do: device
  defp join(device, rest), do: device <> " — " <> rest

  defp describe(%{standby?: true}), do: "Standby"

  defp describe(%{playing?: true} = state), do: doing("Playing", state)
  defp describe(%{paused?: true} = state), do: doing("Paused", state)
  defp describe(_state), do: nil

  defp doing(verb, state) do
    case track(state) do
      nil ->
        nil

      words ->
        Enum.join([verb, words, elapsed(state), from(state)] |> Enum.reject(&is_nil/1), " ")
    end
  end

  defp track(%{stream_title: title}) when is_binary(title) and title != "", do: title

  defp track(%{item: %{title: title} = item}) when is_binary(title) do
    case Map.get(item, :subtitle) do
      line when is_binary(line) and line != "" -> title <> " · " <> line
      _other -> title
    end
  end

  defp track(_state), do: nil

  defp elapsed(%{item: %{duration_ms: total}, position_ms: at})
       when is_integer(total) and total > 0 and is_integer(at) do
    "(" <> clock(at) <> "/" <> clock(total) <> ")"
  end

  defp elapsed(_state), do: nil

  defp from(%{source: module}) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :title, 0) do
      "from " <> module.title()
    end
  end

  defp from(_state), do: nil

  defp clock(ms) do
    seconds = div(ms, 1000)
    {hours, minutes, secs} = {div(seconds, 3600), rem(div(seconds, 60), 60), rem(seconds, 60)}

    if hours > 0 do
      "#{hours}:#{pad(minutes)}:#{pad(secs)}"
    else
      "#{minutes}:#{pad(secs)}"
    end
  end

  defp pad(number), do: String.pad_leading(to_string(number), 2, "0")
end
