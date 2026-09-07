defmodule MyHiFi.Device.Identity do
  @moduledoc """
  What this device is called, and the picture that it shows when it plays nothing.

  A household holds more than one of these, so a person names each one. The name
  reaches five places:

  - The mDNS advertisement, so a browser reaches `<name>.local`.
  - The access point of the Wi-Fi wizard, so a person knows which device asks.
  - Each screen of the device, when the player plays nothing.
  - The title of each page of the web interface.
  - The `Device` field that a Jellyfin server lists. See `MyHiFi.Jellyfin.Server`.

  **The name lives in the firmware key store, and not in the settings table.** Three
  reasons, and the first one decides it.

  - `MyHiFi.Application` starts the Wi-Fi wizard **before** the Repo, because setup
    mode and normal operation cannot happen together. A name in the database is
    therefore unreadable in the one mode that needs it for the access point.
  - `fwup` writes the same block when a person makes an SD card, so a factory can name
    a device before it ever starts. The `provisioning.conf` of the Nerves system holds
    the line that does it, beside the serial number.
  - An upgrade keeps what the block holds. `uboot_clearenv` runs in the `complete`
    task of that system and in no upgrade task, so the name goes when the card is
    written and at no other time.

  The host keeps the value in memory alone, because `nerves_runtime` gives a host
  build the in-memory backend. A name that a person sets in development therefore
  lasts as long as the node.

  **The name of the board does not move.** erlinit sets the hostname at the boot, and
  no dependency of this firmware holds a call to change it after that. The device
  therefore answers for `<name>.local` **and** for `nerves-<serial>.local`, and
  `MdnsLite.set_hosts/1` puts the name of the person first, so the advertisement of
  the web service carries it.

  ## The picture

  `MyHiFi.Artwork` holds it, in the way that it holds the logo of a station: the same
  store, the same thumbnail, the same address, and the same rule about which types
  this firmware serves. A screen therefore reads the splash through the path that it
  reads a cover with, and `MyHiFi.Peripheral.PiTft.asset_options/0` needs no change.

  The name of the entry is the hash of the bytes, so it holds 64 characters like every
  other name of that module. See `MyHiFi.Artwork.put/1`.
  """

  alias MyHiFi.Artwork
  alias MyHiFi.Event
  alias MyHiFi.Event.Device.IdentityChanged
  alias MyHiFi.Settings
  alias Nerves.Runtime.KV

  # A key of this firmware, beside the `nerves_` keys of the Nerves project. The block
  # holds 8 KB, and a name of 32 bytes is nothing beside what the firmware metadata
  # already takes.
  @name_key "myhifi_device_name"

  @default_name "MyHiFi"
  @default_slug "myhifi"

  # An SSID takes 32 bytes, and `VintageNetWizard.APMode` cuts a longer one at that
  # point. A name that a person reads on a phone is therefore whole.
  @max_bytes 32

  @splash_key "device.splash"

  @doc """
  The name that this device answers to.

  It gives `MyHiFi` for a device that no person named.
  """
  @spec name() :: String.t()
  def name do
    case KV.get(@name_key) do
      name when is_binary(name) and name != "" -> name
      _other -> @default_name
    end
  end

  @doc """
  The name of a device that no person named.

  Each screen draws this in a view that carries no name, so the default lives here and
  not in the layout of each screen.

      iex> MyHiFi.Device.Identity.default_name()
      "MyHiFi"
  """
  @spec default_name() :: String.t()
  def default_name, do: @default_name

  @doc """
  Name this device.

  It writes the name, it tells the network, and it publishes
  `MyHiFi.Event.Device.IdentityChanged`, so each screen and each open page draws the
  new name at once.

  The error is a sentence, because a person typed the value.
  """
  @spec put_name(String.t()) :: :ok | {:error, String.t()}
  def put_name(name) do
    with {:ok, name} <- checked(name),
         :ok <- KV.put(@name_key, name) do
      announce()
      publish()
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "The device kept its name: #{inspect(reason)}"}
    end
  end

  @doc """
  The name in the form that a host name takes.

  mDNS holds one label of lower case letters, digits and hyphens, and a person writes
  spaces and capitals. A name that gives no label at all, such as one of Japanese
  characters, gives the default.

      iex> MyHiFi.Device.Identity.slug("Kitchen HiFi")
      "kitchen-hifi"

      iex> MyHiFi.Device.Identity.slug("音楽")
      "myhifi"
  """
  @spec slug(String.t()) :: String.t()
  def slug(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "", do: @default_slug, else: slug
  end

  @doc "The name of this device, in the form that a host name takes."
  @spec slug() :: String.t()
  def slug, do: slug(name())

  @doc """
  Tell the network what this device is called.

  `MyHiFi.Application` calls this at each boot, because the advertisement lives in
  memory and the name lives on the card. `put_name/1` calls it again.

  The host does nothing here. `mdns_lite` arrives through `nerves_pack`, which is a
  target dependency, so a reference to it must not reach a host build. See
  `MyHiFi.Setup`, which does the same for the wizard.
  """
  @spec announce() :: :ok
  def announce, do: do_announce()

  @doc """
  The address of the picture that the device shows when it plays nothing.

  It gives `nil` for a device that holds no picture. The address is the one that
  `MyHiFi.Artwork` serves, so a page draws it and a screen reads the thumbnail of it.
  """
  @spec splash_path() :: String.t() | nil
  def splash_path do
    case splash_name() do
      nil -> nil
      name -> "/artwork/#{name}"
    end
  end

  @doc "The name of the entry that holds the picture, or `nil` for a device with none."
  @spec splash_name() :: String.t() | nil
  def splash_name do
    case Settings.fetch(@splash_key) do
      {:ok, setting} -> setting.value
      {:error, _reason} -> nil
    end
  end

  @doc """
  Hold the picture that a person gave, and show it on each screen.

  The picture that was there goes, unless the person gave the same bytes again: the
  name of an entry is the hash of the bytes, so the two are one entry in that case.

  The error is a sentence, because a person chose the file.
  """
  @spec put_splash(binary()) :: :ok | {:error, String.t()}
  def put_splash(bytes) when is_binary(bytes) do
    previous = splash_name()

    case Artwork.put(bytes) do
      {:ok, name} ->
        Settings.put!(@splash_key, name)
        if previous && previous != name, do: Artwork.remove(previous)
        publish()

      {:error, reason} ->
        {:error, refusal(reason)}
    end
  end

  @doc """
  Take the picture away.

  Each screen then shows the name of the device on the field that it draws for a
  track with no artwork.
  """
  @spec remove_splash() :: :ok
  def remove_splash do
    case Settings.fetch(@splash_key) do
      {:ok, setting} ->
        Artwork.remove(setting.value)
        Settings.delete!(setting)
        publish()

      {:error, _reason} ->
        :ok
    end
  end

  defp checked(name) when is_binary(name) do
    name = String.trim(name)

    cond do
      name == "" -> {:error, "A device needs a name."}
      byte_size(name) > @max_bytes -> {:error, "A name holds #{@max_bytes} characters or less."}
      not readable?(name) -> {:error, "A name holds characters that a person reads."}
      true -> {:ok, name}
    end
  end

  defp checked(_name), do: {:error, "A device needs a name."}

  # A control character reads as nothing on a screen, and it makes an SSID that a phone
  # shows wrong. `String.printable?/1` allows a line feed and a tab, so this refuses
  # every character of that class as well.
  defp readable?(name) do
    String.printable?(name) and not String.match?(name, ~r/\p{C}/u)
  end

  defp publish do
    Event.publish(:device, %IdentityChanged{name: name(), splash_path: splash_path()})
  end

  defp refusal({:not_an_image, _type}), do: "That file is not a JPEG and not a PNG."

  defp refusal({:too_large, bytes}),
    do: "That file holds #{div(bytes, 1024)} KB, and a picture takes 4096 KB or less."

  # The first bytes of the file say JPEG or PNG, and the rest of it says something else.
  # `vipsthumbnail` is what reads the rest, so a file that is broken or that is not a
  # picture at all arrives here and not at the check of the type.
  defp refusal({:vipsthumbnail_failed, _status, _output}),
    do: "That file is not a picture that this device can read."

  defp refusal(reason), do: "The device kept the picture that it had: #{inspect(reason)}"

  if Mix.target() == :host do
    defp do_announce, do: :ok
  else
    defp do_announce do
      # The first name of the list carries the advertisement of each service, so the
      # name of the person comes before the name of the board. `nerves.local` is absent
      # on purpose: a household with two devices gets one answer that it cannot predict.
      MdnsLite.set_hosts([slug(), :hostname])
      MdnsLite.set_instance_name(name())
    end
  end
end
