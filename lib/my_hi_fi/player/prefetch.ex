defmodule MyHiFi.Player.Prefetch do
  @moduledoc """
  Reads the audio of the next track before the current one ends.

  A track that plays from a file waits for the network twice: once for the request,
  and once for the first 64 KB that `MyHiFi.Player.FileSource` holds before the first
  sound. Both of those waits sit between one track and the next, where a person hears
  them as a gap. This removes them, by reading the file while the track before it
  still plays.

  **It does not make the change of track gapless.** `MyHiFi.Output.APlaySink` starts
  `aplay` for each pipeline, and that start holds a silence of about one second. Only
  a sink that lives longer than one pipeline can remove that, and this firmware
  builds a pipeline for each playable. See `MyHiFi.Player.Pipeline`.

  ## What it reads, and what it leaves

  **A track of the `:download` transport, and nothing else.** A live stream has no
  next byte to read early, and an HLS playlist holds its own buffer.

  **One track ahead.** `MyHiFi.Playback.Queue.NextUp` gives the row after the one
  that plays, and this asks for that one alone. A person who skips through a list
  costs the card one file, and not five.

  ## The file does not hold the card

  `MyHiFi.Player.Download` writes each file with `keep?`, which no eviction may take.
  That mark is right for a file that a person is in the middle of, and wrong for a
  file that this module read for a track that a person may never reach. **This
  therefore releases the entry as soon as the file is whole.** Without that a person
  who stops before the next track leaves a file that nothing releases, in the way that
  a stopped song did before `MyHiFi.Player.release_file/1`.

  ## Why a task, and not the player

  `MyHiFi.Player.Download.ensure/2` makes its caller a watcher, so every count of
  bytes reaches that process. The player must answer a person who presses a control,
  and a mailbox of one message for each 16 KB of a 40 MB file is not the way to do
  that. A task therefore holds the wait, and the player asks and forgets.
  """

  require Logger

  alias MyHiFi.Player.Download
  alias MyHiFi.Source

  # A track of 40 MB over a local network takes seconds, and the same track over slow
  # Wi-Fi takes a minute. Ten minutes is longer than any one track, and it ends a task
  # that waits for a download that will never answer.
  @wait :timer.minutes(10)

  @doc """
  Read the audio of one item, and answer at once.

  It gives `:ok` for a track that it began to read, and `:ignored` for one that holds
  nothing to read early. A person is in the middle of a track while this runs, so it
  raises nothing and it logs what did not work.
  """
  @spec ask(MyHiFi.Playback.Item.t()) :: :ok | :ignored
  def ask(item) do
    case playable(item) do
      {:ok, %{transport: :download, key: key, uri: uri}} ->
        read(key, uri, item)

      _other ->
        :ignored
    end
  end

  defp playable(item) do
    with {:ok, module} <- Source.from_slug(item.source) do
      module.resolve(item)
    end
  end

  # `Task.start/1` and not a supervised task: this work is worth nothing on its own,
  # and a task that dies leaves the track to read itself when a person reaches it.
  defp read(key, uri, item) do
    {:ok, _pid} = Task.start(fn -> hold(key, uri, item) end)

    :ok
  end

  defp hold(key, uri, item) do
    case Download.ensure(key, uri) do
      {:ok, %{complete?: true}} -> Download.release(key)
      {:ok, %{complete?: false}} -> wait(key, item)
      {:error, reason} -> failed(item, reason)
    end
  end

  defp wait(key, item) do
    receive do
      {:download, :done} ->
        Download.release(key)

      {:download, {:error, reason}} ->
        failed(item, reason)

      {:download, {:bytes, _count}} ->
        wait(key, item)
    after
      @wait -> failed(item, :timeout)
    end
  end

  defp failed(item, reason) do
    Logger.info("Could not read #{item.title} before it plays: #{inspect(reason)}")

    :ok
  end
end
