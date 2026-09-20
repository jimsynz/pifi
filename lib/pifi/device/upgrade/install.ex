defmodule PiFi.Device.Upgrade.Install do
  @moduledoc """
  Puts one firmware on the card and restarts the device.

  Three steps, and each one can stop the upgrade with nothing lost.

  1. **Write the firmware to `/root`.** It arrives at whatever rate the network gives,
     and `fwup` reads a file and not a socket, so the bytes land on the card first. That
     is one write of about 30 MB for an upgrade, which is less than a single podcast
     episode.
  2. **Check it against the `.sha256` that the build attached.** A download that stopped
     half way is the failure to expect, and it must be caught before anything reaches
     the boot partition. `fwup` would also refuse a broken archive, but by then it has
     written the partition that the device is about to boot from.
  3. **Apply it, and reboot.** `fwup --task upgrade` writes the partition that is not
     running, and the bootloader takes it at the next start. A device that loses power
     in the middle of that still boots the partition that it has.

  **The file goes whatever happens.** A firmware that was applied is of no more use, and
  a firmware that failed must not be tried again from a copy that nothing checked.

  ## It runs on a device and nowhere else

  `fwup` is part of the Nerves system, and a host has no partition to write. A host
  therefore refuses before it reads a byte, rather than put 30 MB in somebody's home
  directory for nothing.
  """

  # Sobelow reads `@sobelow_skip` from the source. This registration stops the
  # compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc """
  Fetch one release, apply it, and restart.

  `progress` is called with the percentage of the download as it arrives, so a page can
  draw a bar. It returns `:ok` and the device then reboots, so no caller reads that
  answer for long.
  """
  @spec run(PiFi.Device.Upgrade.Forge.release(), (non_neg_integer() -> any())) ::
          :ok | {:error, term()}
  def run(release, progress)

  if Mix.target() == :host do
    def run(_release, _progress), do: {:error, :not_a_device}
  else
    require Logger

    alias Nerves.Runtime.KV
    alias PiFi.Device.Upgrade
    alias PiFi.Device.Upgrade.Forge

    # A read of 30 MB over the Wi-Fi of a home takes a while, and a device that gave up
    # on a slow network would never upgrade at all.
    @timeout :timer.minutes(20)

    # Sobelow reads the two names below as though a person typed them. Both come from
    # `config/config.exs` and from `Mix.target()`, and no request reaches either one.
    @sobelow_skip ["Traversal.FileModule"]
    def run(release, progress) do
      path = Path.join(Upgrade.download_path(), Upgrade.firmware_name())

      try do
        with :ok <- download(release.url, path, progress),
             :ok <- verify(path, release.sha256_url) do
          apply_firmware(path)
        end
      after
        File.rm(path)
      end
    end

    @sobelow_skip ["Traversal.FileModule"]
    defp download(url, path, progress) do
      File.mkdir_p!(Path.dirname(path))
      file = File.open!(path, [:write, :binary])

      try do
        case Req.get(request(url: url, into: writer(file, progress))) do
          {:ok, %{status: 200}} -> :ok
          {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
          {:error, reason} -> {:error, reason}
        end
      after
        File.close(file)
      end
    end

    # **A page draws a bar, and a bar moves in whole percentages.** A chunk of the wire
    # is a few kilobytes, so a report for each one would be thousands of messages for
    # one step of the bar. This reports when the number changes and at no other time.
    defp writer(file, progress) do
      counter = :counters.new(2, [])

      fn {:data, data}, {request, response} ->
        :ok = IO.binwrite(file, data)
        :counters.add(counter, 1, byte_size(data))

        percent = percent(:counters.get(counter, 1), length_of(response))

        if percent > :counters.get(counter, 2) do
          :counters.put(counter, 2, percent)
          progress.(percent)
        end

        {:cont, {request, response}}
      end
    end

    defp percent(_read, 0), do: 0
    defp percent(read, total), do: min(div(read * 100, total), 100)

    defp length_of(response) do
      case Req.Response.get_header(response, "content-length") do
        [length | _rest] -> String.to_integer(length)
        [] -> 0
      end
    end

    # **The file names the digest, and the build wrote the name beside it.**
    # `sha256sum` writes `<digest>  <name>`, so the first word is the whole of what this
    # compares.
    @sobelow_skip ["Traversal.FileModule"]
    defp verify(path, sha256_url) do
      with {:ok, body} <- Forge.read(sha256_url) do
        expected = body |> String.split() |> List.first()
        digest = path |> File.stream!(2048) |> Enum.reduce(:crypto.hash_init(:sha256), &hash/2)

        case Base.encode16(:crypto.hash_final(digest), case: :lower) do
          ^expected -> :ok
          _other -> {:error, :wrong_digest}
        end
      end
    end

    defp hash(chunk, state), do: :crypto.hash_update(state, chunk)

    defp request(options) do
      options
      |> Keyword.merge(receive_timeout: @timeout, retry: :transient)
      |> Keyword.merge(Application.get_env(:pifi, Forge, []))
      |> Req.new()
    end

    # `nerves_fw_devpath` is what the running firmware was written to, so this asks the
    # device rather than name a card that another board spells differently.
    defp apply_firmware(path) do
      device = KV.get("nerves_fw_devpath") || "/dev/rootdisk0"

      arguments = ["--apply", "--task", "upgrade", "--no-unmount", "-d", device, "-i", path]

      case System.cmd("fwup", arguments, stderr_to_stdout: true) do
        {_output, 0} ->
          Nerves.Runtime.reboot()

          :ok

        {output, code} ->
          Logger.error("fwup refused the firmware (#{code}): #{output}")

          {:error, :fwup_refused}
      end
    end
  end
end
