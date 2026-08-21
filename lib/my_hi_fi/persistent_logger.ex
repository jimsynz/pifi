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
  """

  @path "/dev/pmsg0"
  @max_bytes 800

  @doc """
  Add this handler to the log.

  It takes the level from `:level`, and `:info` is the default. A device logs at
  `:debug` in memory, and that is too much for a window of this size.
  """
  @spec attach(keyword()) :: :ok | {:error, term()}
  def attach(options \\ []) do
    level = Keyword.get(options, :level, :info)

    :logger.add_handler(:myhifi_persistent, __MODULE__, %{level: level, config: %{}})
  end

  @doc """
  Read the log of the boot before this one.

  It gives `{:error, :enoent}` when the last restart was an orderly one, because
  ramoops keeps a record of an unclean reset only.
  """
  @spec last_boot() :: {:ok, String.t()} | {:error, term()}
  def last_boot, do: File.read("/sys/fs/pstore/pmsg-ramoops-0")

  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{level: level, msg: message, meta: meta}, _config) do
    line = "#{stamp(meta)} myhifi #{level}: #{text(message)}\n"
    _ = File.write(@path, String.slice(line, 0, @max_bytes), [:append])
    :ok
  end

  def log(_event, _config), do: :ok

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
