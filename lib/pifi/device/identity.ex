defmodule PiFi.Device.Identity do
  @moduledoc """
  What this device is called, and the picture that it shows when it plays nothing.

  A household has more than one of these, so a person names each one. The name
  reaches five places:

  - The mDNS advertisement, so a browser reaches `<name>.local`.
  - The access point of the Wi-Fi wizard, so a person knows which device asks.
  - Each screen of the device, when the player plays nothing.
  - The title of each page of the web interface.
  - The `Device` field that a Jellyfin server lists. See `PiFi.Jellyfin.Server`.

  **The name lives in the firmware key store, and not in the settings table.** Three
  reasons, and the first one decides it.

  - `PiFi.Application` starts the Wi-Fi wizard **before** the Repo, because setup
    mode and normal operation cannot happen together. A name in the database is
    therefore unreadable in the one mode that needs it for the access point.
  - `fwup` writes the same block when a person makes an SD card, so a factory can name
    a device before it ever starts. The `provisioning.conf` of the Nerves system carries
    the line that does it, beside the serial number.
  - An upgrade keeps what the block carries. `uboot_clearenv` runs in the `complete`
    task of that system and in no upgrade task, so the name goes when the card is
    written and at no other time.

  The host keeps the value in memory alone, because `nerves_runtime` gives a host
  build the in-memory backend. A name that a person sets in development therefore
  lasts as long as the node.

  **Two more keys of that block belong to the build, and not to the device.**
  `myhifi_product_name` is what the product is called, and `myhifi_splash_name` names
  the picture that it ships. A person provisions those with `fwup`, so one firmware
  serves several products and neither one needs a build of its own. See `default_name/0`
  and `shipped_splash/1`.

  **The name of the board does not move.** erlinit sets the hostname at the boot, and
  no dependency of this firmware makes a call to change it after that. The device
  therefore answers for `<name>.local` **and** for `nerves-<serial>.local`, and
  `MdnsLite.set_hosts/1` puts the name of the person first, so the advertisement of
  the web service carries it.

  ## The picture

  **A screen that plays nothing draws the mark of the product**, and a person who gives
  a picture of their own draws that instead. `shipped_splash/1` gives the first and
  `splash_path/0` gives the second, and a screen asks for the person's one first.

  `PiFi.Artwork` keeps the picture of a person, in the way that it keeps the logo of a
  station: the same store, the same thumbnail, the same address, and the same rule about
  which types this firmware serves. A screen therefore reads the splash through the path that it
  reads a cover with, and `PiFi.Screen.Renderer.assets/0` needs no change.

  The name of the entry is the hash of the bytes, so it is 64 characters like every
  other name of that module. See `PiFi.Artwork.put/1`.
  """

  alias Nerves.Runtime.KV
  alias PiFi.Artwork
  alias PiFi.Event
  alias PiFi.Event.Device.IdentityChanged
  alias PiFi.Settings

  # The keys of this firmware, beside the `nerves_` keys of the Nerves project. The
  # block takes 8 KB, and these three take a few dozen bytes of it.
  #
  # **One of them belongs to the device and two belong to the build.**
  # `pifi_device_name` is what a person called this device.
  # `pifi_product_name` and `pifi_splash_name` are what the product is called and
  # which picture it ships, so `fwup` provisions a brand and one firmware serves
  # several. See `default_name/0` and `shipped_splash/1`.
  @name_key "pifi_device_name"
  @product_key "pifi_product_name"
  @splash_name_key "pifi_splash_name"

  # **The product was called MyHiFi, and a board that was made then holds those keys.**
  # No upgrade task runs `uboot_clearenv`, so the old block survives a new firmware. A
  # read that asked for the new name alone would find nothing, and the device would
  # lose the name that a person gave it. `read/1` therefore reads the new key and uses
  # the old one when the new one is absent.
  #
  # **A write always uses the new key.** The old one then stays in the block, unread,
  # until a person writes a card. That costs a few dozen bytes of 8 KB, and it is the
  # price of never losing a name.
  @former_keys %{
    "pifi_device_name" => "myhifi_device_name",
    "pifi_product_name" => "myhifi_product_name",
    "pifi_splash_name" => "myhifi_splash_name"
  }

  @default_name "PiFi"
  @default_splash_name "pifi"
  @default_slug "pifi"

  # An SSID takes 32 bytes, and `VintageNetWizard.APMode` cuts a longer one at that
  # point. A name that a person reads on a phone is therefore whole.
  @max_bytes 32

  @splash_key "device.splash"

  # Where the pictures that this firmware ships live, under the application directory.
  # One file for each screen that this firmware drives, named for its size.
  @shipped "priv/splash"

  @doc """
  The name that this device answers to.

  It returns the name of the product for a device that no person named, which is `PiFi`
  until a provisioner says otherwise. See `default_name/0`.
  """
  @spec name() :: String.t()
  def name do
    case read(@name_key) do
      name when is_binary(name) and name != "" -> name
      _other -> default_name()
    end
  end

  @doc """
  The name of the product, which is the name of a device that no person named.

  Each screen draws this in a view that carries no name, so the default lives here and
  not in the layout of each screen.

  **A provisioner names it, so one firmware serves several products.**
  `myhifi_product_name` of the firmware key store carries it, `fwup` writes that block
  when a person makes an SD card, and a build that provisions nothing answers `PiFi`.
  The `provisioning.conf` of the Nerves system is where such a line goes, beside the
  serial number.

      iex> PiFi.Device.Identity.default_name()
      "PiFi"
  """
  @spec default_name() :: String.t()
  def default_name, do: provisioned(@product_key, @default_name)

  @doc """
  Name this device.

  It writes the name, it tells the network, and it publishes
  `PiFi.Event.Device.IdentityChanged`, so each screen and each open page draws the
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
      {:error, reason} -> {:error, "The device did not change its name: #{inspect(reason)}"}
    end
  end

  @doc """
  The name in the form that a host name takes.

  mDNS takes one label of lower case letters, digits and hyphens, and a person writes
  spaces and capitals. A name that gives no label at all, such as one of Japanese
  characters, gives the default.

      iex> PiFi.Device.Identity.slug("Kitchen HiFi")
      "kitchen-hifi"

      iex> PiFi.Device.Identity.slug("音楽")
      "pifi"
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

  `PiFi.Application` calls this at each boot, because the advertisement lives in
  memory and the name lives on the card. `put_name/1` calls it again.

  The host does nothing here. `mdns_lite` arrives through `nerves_pack`, which is a
  target dependency, so a reference to it must not reach a host build. See
  `PiFi.Setup`, which does the same for the wizard.
  """
  @spec announce() :: :ok
  def announce, do: do_announce()

  @doc """
  The address of the picture that the device shows when it plays nothing.

  It returns `nil` for a device with no picture. The address is the one that
  `PiFi.Artwork` serves, so a page draws it and a screen reads the thumbnail of it.
  """
  @spec splash_path() :: String.t() | nil
  def splash_path do
    case splash_name() do
      nil -> nil
      name -> "/artwork/#{name}"
    end
  end

  @doc """
  The picture that this firmware ships, for a screen of one size.

  **A device that a person has given no picture is not a device with no picture.** The
  firmware ships one for each screen that it drives, drawn at the size of that screen,
  so a screen that plays nothing shows the mark of the product and not a dark field.

  It returns `nil` for a size that this firmware ships no picture for, and a screen then
  draws its own field. A new screen therefore needs a file and no code.

  The file is a PNG of exactly the size of the screen. **A picture of another size
  would cost a scale for each draw**, and one that a screen has to crop would lose the
  ends of the waveform of this one; `PiFi.Screen.Renderer.assets/0` names this
  directory so that Emerge may read it.

  **A provisioner names the set, so one firmware carries the artwork of several
  products.** `myhifi_splash_name` of the firmware key store carries the name in front of
  the size, `fwup` writes that block when a person makes an SD card, and a build that
  provisions nothing reads `pifi-320x240.png`. `priv/splash` is the list of the sets
  that this firmware ships, and a product that a person adds needs a file for each
  screen and no code at all.

      iex> PiFi.Device.Identity.shipped_splash({7, 7})
      nil

  """
  @spec shipped_splash({pos_integer(), pos_integer()}) :: Path.t() | nil
  def shipped_splash({width, height}) do
    path = Path.join(splash_directory(), "#{shipped_name()}-#{width}x#{height}.png")

    if File.exists?(path), do: path
  end

  @doc """
  Where the pictures that this firmware ships live.

  A test names another directory with `:splash_directory`. Nothing sets it in
  production, in the way that nothing sets `:cache_limit`.
  """
  @spec splash_directory() :: Path.t()
  def splash_directory do
    Application.get_env(:pifi, :splash_directory, Application.app_dir(:pifi, @shipped))
  end

  @doc "The name of the entry of the picture, or `nil` for a device with none."
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
      byte_size(name) > @max_bytes -> {:error, "A name takes #{@max_bytes} characters or less."}
      not readable?(name) -> {:error, "A name needs characters that a person can read."}
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

  # The name in front of the size, which a provisioner writes and a build that
  # provisions nothing reads as `pifi`. `splash_name/0` above is another thing: the
  # entry of the cache that keeps the picture of a person.
  defp shipped_name, do: provisioned(@splash_name_key, @default_splash_name)

  # **A value of the build, and not of the device.** `fwup` writes the block, so a
  # value here changes when a person makes a card and at no other time.
  defp provisioned(key, default) do
    case read(key) do
      value when is_binary(value) and value != "" -> value
      _other -> default
    end
  end

  # The new key, and the key of the former name of the product when the new one holds
  # nothing. See `@former_keys`.
  defp read(key) do
    case KV.get(key) do
      value when is_binary(value) and value != "" -> value
      _other -> KV.get(Map.fetch!(@former_keys, key))
    end
  end

  defp publish do
    Event.publish(:device, %IdentityChanged{name: name(), splash_path: splash_path()})
  end

  defp refusal({:not_an_image, _type}), do: "That file is not a JPEG and not a PNG."

  defp refusal({:too_large, bytes}),
    do: "That file is #{div(bytes, 1024)} KB, and a picture takes 4096 KB or less."

  # The first bytes of the file say JPEG or PNG, and the rest of it says something else.
  # `vipsthumbnail` is what reads the rest, so a file that is broken or that is not a
  # picture at all arrives here and not at the check of the type.
  defp refusal({:vipsthumbnail_failed, _status, _output}),
    do: "That file is not a picture that this device can read."

  defp refusal(reason), do: "The device did not change its picture: #{inspect(reason)}"

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
