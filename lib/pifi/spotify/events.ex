defmodule PiFi.Spotify.Events do
  @moduledoc """
  Reads what librespot says about itself.

  **`--onevent PROGRAM` is the whole interface.** librespot writes nothing about its
  state to standard output and listens on no socket: it runs a program and puts the
  facts in that program's environment. The program inherits librespot's standard
  output, so a script that prints its own environment turns the environment into a
  stream that this firmware can read.

  `priv/spotify/librespot-event` is that script. It prints a line to open a block, runs
  `env`, and prints a line to close it.

  ## Why a block and not a line

  **`env` writes its variables in no particular order**, so a reader cannot know which
  variable ends an event. The closing line is what says so, and without it every event
  would have to wait for the next one to arrive before it could be read — which for the
  last event of a cast is for ever.

  librespot runs one event program at a time and waits for it, so two blocks never
  interleave.

  ## What is worth reading

  `--emit-sink-events` adds `SINK_STATUS`, and those three values are the ones that
  matter most: they say when librespot opens the sound path and when it lets go.
  `PiFi.Spotify` starts and stops the capture on them.

  - `running` — a cast has begun.
  - `temporarily_closed` — a person pressed pause.
  - `closed` — the cast is over.

  The rest is a now playing card: `track_changed` carries `NAME`, `ARTISTS`, `ALBUM`,
  `DURATION_MS` and `COVERS`, and `playing`, `paused` and `seeked` carry `POSITION_MS`.

  **The environment holds far more than this**, because it is the whole environment of
  the daemon. Only the names below are kept, so `PATH` and its neighbours never reach
  anything that reads an event.
  """

  @opening "--- pifi event ---"
  @closing "--- pifi event end ---"

  @keys ~w[
    PLAYER_EVENT SINK_STATUS TRACK_ID OLD_TRACK_ID NAME ARTISTS ALBUM ALBUM_ARTISTS
    DURATION_MS POSITION_MS COVERS VOLUME NUMBER DISC_NUMBER URI
  ]

  @typedoc "One thing that librespot said, with the names it is worth keeping."
  @type event :: %{String.t() => String.t()}

  @doc """
  The line that opens a block.

      iex> PiFi.Spotify.Events.opening()
      "--- pifi event ---"
  """
  @spec opening() :: String.t()
  def opening, do: @opening

  @doc """
  The line that closes a block.

      iex> PiFi.Spotify.Events.closing()
      "--- pifi event end ---"
  """
  @spec closing() :: String.t()
  def closing, do: @closing

  @doc """
  Take whatever blocks are complete out of what has arrived so far.

  It returns the events in the order that they were written and whatever is left over,
  which a caller keeps and passes back with the next bytes from the port.

      iex> PiFi.Spotify.Events.take("--- pifi event ---\\nPLAYER_EVENT=playing\\nPOSITION_MS=56000\\n--- pifi event end ---\\n")
      {[%{"PLAYER_EVENT" => "playing", "POSITION_MS" => "56000"}], ""}

  A block that has not finished arriving stays in the leftover:

      iex> PiFi.Spotify.Events.take("--- pifi event ---\\nPLAYER_EVENT=playing\\n")
      {[], "--- pifi event ---\\nPLAYER_EVENT=playing\\n"}

  **Anything before the opening line is dropped.** librespot writes its own log to
  standard error, but a program it runs may write to standard output for reasons of its
  own, and a line that is not inside a block is not an event.

      iex> PiFi.Spotify.Events.take("noise\\n--- pifi event ---\\nSINK_STATUS=running\\n--- pifi event end ---\\n")
      {[%{"SINK_STATUS" => "running"}], ""}

  """
  @spec take(String.t()) :: {[event()], String.t()}
  def take(buffer), do: take(buffer, [])

  defp take(buffer, found) do
    with [_before, rest] <- String.split(buffer, @opening <> "\n", parts: 2),
         [block, rest] <- String.split(rest, @closing <> "\n", parts: 2) do
      take(rest, [parse(block) | found])
    else
      _incomplete -> {Enum.reverse(found), keep(buffer)}
    end
  end

  # **Only from the opening line onwards is worth keeping.** Anything before it is not
  # part of an event, and holding it would grow without bound on a daemon that writes to
  # standard output for any other reason.
  defp keep(buffer) do
    case String.split(buffer, @opening <> "\n", parts: 2) do
      [_before, rest] -> @opening <> "\n" <> rest
      [_only] -> ""
    end
  end

  defp parse(block) do
    block
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] when key in @keys -> [{key, value}]
        _other -> []
      end
    end)
    |> Map.new()
  end

  @doc """
  What the sound path of librespot is doing, for an event that says.

  `nil` is an event that says nothing about it, which is most of them.

      iex> PiFi.Spotify.Events.sink(%{"SINK_STATUS" => "running"})
      :running

      iex> PiFi.Spotify.Events.sink(%{"SINK_STATUS" => "temporarily_closed"})
      :paused

      iex> PiFi.Spotify.Events.sink(%{"PLAYER_EVENT" => "playing"})
      nil

  """
  @spec sink(event()) :: :running | :paused | :closed | nil
  def sink(%{"SINK_STATUS" => "running"}), do: :running
  def sink(%{"SINK_STATUS" => "temporarily_closed"}), do: :paused
  def sink(%{"SINK_STATUS" => "closed"}), do: :closed
  def sink(_event), do: nil

  @doc """
  The track of an event that carries one.

  `ARTISTS` holds more than one name, separated by a newline, and this keeps them that
  way behind a comma so that a surface can draw them. `nil` is an event with no track.

      iex> PiFi.Spotify.Events.track(%{"NAME" => "DNH", "ARTISTS" => "Tove Lo", "DURATION_MS" => "147000"})
      %{title: "DNH", artists: "Tove Lo", album: nil, duration_ms: 147000, artwork: nil}

      iex> PiFi.Spotify.Events.track(%{"PLAYER_EVENT" => "playing"})
      nil

  """
  @spec track(event()) :: map() | nil
  def track(%{"NAME" => name} = event) when is_binary(name) and name != "" do
    %{
      title: name,
      artists: event |> Map.get("ARTISTS") |> names(),
      album: Map.get(event, "ALBUM"),
      duration_ms: event |> Map.get("DURATION_MS") |> whole(),
      artwork: event |> Map.get("COVERS") |> first_line()
    }
  end

  def track(_event), do: nil

  @doc """
  Where librespot is in the track, for an event that says.

      iex> PiFi.Spotify.Events.position(%{"POSITION_MS" => "56000"})
      56000

      iex> PiFi.Spotify.Events.position(%{})
      nil

  """
  @spec position(event()) :: non_neg_integer() | nil
  def position(event), do: event |> Map.get("POSITION_MS") |> whole()

  defp names(nil), do: nil
  defp names(""), do: nil
  defp names(value), do: value |> String.split("\n", trim: true) |> Enum.join(", ")

  # **`COVERS` holds one address for each size, largest first.** The first line is the
  # one worth asking for, and `PiFi.Artwork` keeps a thumbnail of whatever it gets.
  defp first_line(nil), do: nil
  defp first_line(""), do: nil
  defp first_line(value), do: value |> String.split("\n", trim: true) |> List.first()

  defp whole(nil), do: nil

  defp whole(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end
end
