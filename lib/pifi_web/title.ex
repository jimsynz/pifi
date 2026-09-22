defmodule PiFiWeb.Title do
  @moduledoc """
  What the tab of a browser says.

  **A person with four tabs open reads the title and nothing else**, and every page of
  this device said the same word. So the name of the device comes first, and what
  follows is whatever is most worth knowing: the track if one is playing, and the page
  if none is.

  ## Playing beats the page

  A person who left this on the settings page and started a record wants the record in
  the tab, not the word "Settings". The page is what the title says when there is
  nothing better to say.

  ## The position is in there, and it costs a message a second

  `PiFi.Event.Player.Progress` arrives once a second while a track plays, and
  `PiFiWeb.Shell` already wakes each page for it. Putting the position in the title
  turns that wake into a small diff to the browser rather than a match and a discard.

  It is rounded to the second before it is compared, so a progress event that lands a
  few milliseconds early writes nothing. A live stream has no length and therefore no
  position: a counter against no total reads as a fault.
  """

  @doc """
  The title for a device, a page and whatever the player is doing.

  `page` is what the page calls itself, and `nil` is a page that has not said.

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

  # **Standby outranks a paused track.** A device in standby is one that a person turned
  # off, and a tab that still named the record would read as a device that is still on.
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

  # **A live stream carries its track in one field and everything else carries two.**
  # Internet radio sends a title over ICY, and that is the whole of what it knows.
  defp track(%{stream_title: title}) when is_binary(title) and title != "", do: title

  # **It is not "by", because `subtitle` is not an artist.** It is documented as "one
  # line under the title, such as the date and the length", and each source fills it
  # with whatever its list rows want: Plex and Jellyfin put the artist there, podcasts
  # put "22 Sep 2026, 44 min" and internet radio puts "MP3, 128 kbps". "by MP3, 128
  # kbps" is the sentence that rule would write. `PiFi.Playback.Item` has no artist and
  # `PiFi.Source` models none, so a title cannot claim one.
  #
  # The dot is what `PiFiWeb.PlayerLive` does with the same field, which is to draw it
  # under the title and say nothing about what it means.
  defp track(%{item: %{title: title} = item}) when is_binary(title) do
    case Map.get(item, :subtitle) do
      line when is_binary(line) and line != "" -> title <> " · " <> line
      _other -> title
    end
  end

  defp track(_state), do: nil

  # A live stream has no end, so it gets no counter: a number against no total reads as
  # a fault rather than as a fact.
  defp elapsed(%{item: %{duration_ms: total}, position_ms: at})
       when is_integer(total) and total > 0 and is_integer(at) do
    "(" <> clock(at) <> "/" <> clock(total) <> ")"
  end

  defp elapsed(_state), do: nil

  # A source names itself, so this needs no list of them. A module that a build left
  # out names nothing rather than raising: a title is not worth an error page.
  defp from(%{source: module}) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :title, 0) do
      "from " <> module.title()
    end
  end

  defp from(_state), do: nil

  # **Hours only when there are hours.** An episode of two hours needs them and a song
  # of three minutes reads worse for the two leading zeros.
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
