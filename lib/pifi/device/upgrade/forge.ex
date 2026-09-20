defmodule PiFi.Device.Upgrade.Forge do
  @moduledoc """
  Reads the releases of this firmware from the forge.

  A tag of the form `v1.2.3` starts a build, and that build attaches one `.fw` for each
  target and a `.sha256` beside it. **The forge is therefore the whole of the release
  channel**, and this device needs no service of its own to learn that a version
  landed.

  The repository is public, so this carries no credential. A person who builds this
  firmware for another forge names the address in `config/config.exs`.

  ## The version of a release is the tag without its `v`

  `Version.compare/2` reads what `mix.exs` holds, and a tag of the forge holds a `v` in
  front of it. A release whose tag is not a version at all is not a release of this
  firmware, and this reports none for it rather than guess.
  """

  alias PiFi.Device.Upgrade

  @timeout :timer.seconds(20)

  @typedoc """
  What the forge says about the newest release.

  `notes` is the body of the tag, which a person reads before they press install.
  `url` and `sha256_url` name the two assets of this target.
  """
  @type release :: %{
          version: String.t(),
          notes: String.t(),
          url: String.t(),
          sha256_url: String.t()
        }

  @doc """
  The newest release that carries a firmware for this target.

  It returns `{:error, :no_firmware}` for a release that holds no asset for this
  target, which is what a tag of a version before this target existed looks like.
  """
  @spec latest() :: {:ok, release()} | {:error, term()}
  def latest do
    with {:ok, body} <- get(),
         {:ok, version} <- version_of(body),
         {:ok, url, sha256_url} <- assets_of(body) do
      {:ok, %{version: version, notes: body["body"] || "", url: url, sha256_url: sha256_url}}
    end
  end

  @doc """
  Read one asset of a release into memory.

  The `.sha256` beside a firmware is one line, so this is for that file and not for the
  firmware itself. See `PiFi.Device.Upgrade.Install`, which writes the firmware to the
  card as it arrives.
  """
  @spec read(String.t()) :: {:ok, binary()} | {:error, term()}
  def read(url) do
    case request(url: url) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get do
    case request(url: Upgrade.releases_url()) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :no_release}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp version_of(%{"tag_name" => "v" <> version}) do
    case Version.parse(version) do
      {:ok, _parsed} -> {:ok, version}
      :error -> {:error, :not_a_version}
    end
  end

  defp version_of(_body), do: {:error, :not_a_version}

  # A release carries a `.fw` and a `.sha256` for each target, so the name of the
  # firmware of this one is what picks the pair out.
  defp assets_of(%{"assets" => assets}) when is_list(assets) do
    name = Upgrade.firmware_name()

    with %{"browser_download_url" => url} <- asset(assets, name),
         %{"browser_download_url" => sha256_url} <- asset(assets, name <> ".sha256") do
      {:ok, url, sha256_url}
    else
      _other -> {:error, :no_firmware}
    end
  end

  defp assets_of(_body), do: {:error, :no_firmware}

  defp asset(assets, name), do: Enum.find(assets, &(&1["name"] == name))

  # A test gives a stub with `config :pifi, PiFi.Device.Upgrade.Forge, plug: ...`, in
  # the way that `PiFi.Plex.Server` takes one. Nothing sets this in production.
  #
  # **Nothing that the wire does may raise here.** `PiFi.Device.Upgrade.Server` calls
  # this, and that process holds what the device knows about the newest firmware. A
  # library that raised for an address a person typed wrong would take the state with
  # it, and the settings page would then answer nothing at all.
  defp request(options) do
    options
    |> Keyword.merge(receive_timeout: @timeout, retry: :transient)
    |> Keyword.merge(Application.get_env(:pifi, __MODULE__, []))
    |> Req.new()
    |> Req.get()
  rescue
    error -> {:error, error}
  end
end
