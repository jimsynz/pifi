defmodule MyHiFi.PersistentLogger do
  @moduledoc """
  Writes the log where it survives a restart.

  `RingLogger` keeps the log in memory, so a restart loses it. That cost real
  time: a board restarted three times while a person looked for a fault, and each
  restart took the evidence away.

  ramoops keeps a reserved part of RAM through a reset, and `pstore` shows what it
  kept. `/dev/pmsg0` is the part of it for a program, and `erlinit` and
  `nerves_heart` already write there. This handler writes the log of this firmware
  to the same place, so one record holds the whole story of the last boot in
  order.

  It costs no write to the SD card.

  `/dev/kmsg` is the wrong place for this. The kernel command line holds `quiet`,
  so the console takes a message of level 3 or lower and drops the rest, and
  ramoops keeps only what the console took. A message of level `info` would
  therefore not survive. `/dev/pmsg0` has no such filter.

  Read the record of the last boot at `/sys/fs/pstore/pmsg-ramoops-0`.

  ## The file on the data partition

  The ramoops window holds 16 KB, and that is not enough for a fault that needs
  the whole story. A deliberate restart of this device is still unexplained,
  because the lines that named the cause fell outside the window.

  This handler therefore also writes each line to `/root/myhifi.log`, and it cuts
  no message there. That file survives an orderly restart as well as a hard one,
  and it holds far more than 16 KB. It costs a write to the SD card, and the
  device writes little: a stream in play logs nothing for each second.

  The file goes to `/root/myhifi.log.1` when it reaches its limit, and the old
  `.1` file goes. Two files therefore hold the log, and the storage stays bounded.
  """

  # A path here comes from the module attributes below, and never from a request.
  # Sobelow reads `@sobelow_skip` from the source, and this registration stops the
  # compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @path "/dev/pmsg0"
  @file_path "/root/myhifi.log"
  @file_max_bytes 256 * 1024

  # The message is cut to this length, and the line ending comes after the cut. An
  # earlier version cut the whole line, so a long message lost its newline and ran
  # into the next entry. Membrane writes a report of several kilobytes when an
  # element fails, and one of those filled the window and broke the framing of
  # everything after it.
  @max_bytes 400

  @doc """
  Add this handler to the log.

  It takes the level from `:level`, and `:info` is the default. A device logs at
  `:debug` in memory, and that is too much for a window of this size.
  """
  @spec attach(keyword()) :: :ok | {:error, term()}
  def attach(options \\ []) do
    level = Keyword.get(options, :level, :info)

    config = %{
      device: Keyword.get(options, :device, @path),
      file: Keyword.get(options, :file, @file_path),
      file_max_bytes: Keyword.get(options, :file_max_bytes, @file_max_bytes)
    }

    :logger.add_handler(:myhifi_persistent, __MODULE__, %{level: level, config: config})
  end

  @doc """
  Read the log file of this device.

  It returns the older file as well when one is there, and the older lines come
  first.
  """
  @sobelow_skip ["Traversal.FileModule"]
  @spec read(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def read(path \\ @file_path) do
    case {File.read(path <> ".1"), File.read(path)} do
      {{:ok, older}, {:ok, newer}} -> {:ok, older <> newer}
      {_absent, {:ok, newer}} -> {:ok, newer}
      {{:ok, older}, _absent} -> {:ok, older}
      {_absent, {:error, reason}} -> {:error, reason}
    end
  end

  @doc """
  Read the log of the boot before this one.

  It returns `{:error, :enoent}` when the last restart was an orderly one, because
  ramoops keeps a record of an unclean reset only.
  """
  @spec last_boot() :: {:ok, String.t()} | {:error, term()}
  def last_boot, do: File.read("/sys/fs/pstore/pmsg-ramoops-0")

  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{level: level, msg: message, meta: meta}, config) do
    settings = settings(config)
    prefix = "#{stamp(meta)} myhifi #{level}: "
    text = text(message)

    # The window of ramoops is small, so a long message is cut there. The file
    # holds the whole message, because a fault that needs the whole story is the
    # reason for the file.
    write(settings.device, prefix <> String.slice(text, 0, @max_bytes) <> "\n")
    write_file(settings, prefix <> text <> "\n")

    :ok
  end

  def log(_event, _config), do: :ok

  defp settings(%{config: %{device: device, file: file, file_max_bytes: max_bytes}}) do
    %{device: device, file: file, file_max_bytes: max_bytes}
  end

  # An older handler holds no such configuration, and a log line must still go
  # somewhere.
  defp settings(_config) do
    %{device: @path, file: @file_path, file_max_bytes: @file_max_bytes}
  end

  # A log line must never stop the firmware. A partition with no room, and a device
  # that is absent, both give an error here, and both are acceptable.
  @sobelow_skip ["Traversal.FileModule"]
  defp write(path, line) when is_binary(path) do
    _ = File.write(path, line, [:append])
    :ok
  end

  defp write(_path, _line), do: :ok

  defp write_file(%{file: nil}, _line), do: :ok

  defp write_file(%{file: path} = settings, line) do
    rotate(path, settings.file_max_bytes)
    write(path, line)
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp rotate(path, max_bytes) do
    case File.stat(path) do
      {:ok, %{size: size}} when size >= max_bytes ->
        _ = File.rename(path, path <> ".1")
        :ok

      _other ->
        :ok
    end
  end

  # The kernel gives the time in microseconds since the epoch.
  defp stamp(%{time: time}) when is_integer(time) do
    time |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  rescue
    _error -> "-"
  end

  defp stamp(_meta), do: "-"

  defp text({:string, chardata}), do: flatten(chardata)
  defp text({:report, report}), do: inspect(report)

  defp text({format, arguments}) when is_list(format) or is_binary(format) do
    format |> :io_lib.format(arguments) |> flatten()
  rescue
    _error -> inspect({format, arguments})
  end

  defp text(other), do: inspect(other)

  defp flatten(chardata) do
    chardata |> IO.chardata_to_string() |> String.replace("\n", " ")
  rescue
    _error -> inspect(chardata)
  end
end
