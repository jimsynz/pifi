defmodule MyHiFi.DeviceSecrets do
  @moduledoc """
  The values that a device makes for itself and keeps.

  A Nerves device has no environment variable that holds a secret, so the firmware
  keeps each value on the application data partition. `MyHiFi.Application` calls
  `put/1` before it starts the endpoint.

  Two values live here.

  - **The endpoint secret.** Every signature and every encrypted cookie of the
    device comes from it, so each device must hold its own.
  - **The LiveView signing salt.** It is not a secret: Plug and LiveView both
    derive a key from the salt **and** the endpoint secret, so two devices already
    hold two different keys. A salt of its own is defence in depth, and it costs
    one file. It must stay the same across a restart, or a session cannot continue
    after a reconnect, so the device writes it once and reads it after that.

  The session cookie salt in `MyHiFiWeb.Endpoint` stays as it is. That one is a
  module attribute, and the socket definitions and the plug pipeline read it while
  the module compiles. A value for each device therefore needs the endpoint
  restructured, and it would change no key that an attacker can already tell apart.
  """

  # The data directory comes from the module attribute or from a test. It never
  # comes from a request. The traversal findings on this module are therefore not
  # correct. Sobelow reads @sobelow_skip from the source. This registration stops
  # the compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @data_dir "/root"
  @secret %{filename: "secret_key_base", byte_count: 48}
  @salt %{filename: "signing_salt", byte_count: 16}

  @doc """
  Give the endpoint its secret and its signing salt, unless it already holds them.

  A value from `config/runtime.exs` or from `config/host.exs` has priority.
  `SECRET_KEY_BASE` in the environment is the manual method for a test or for a
  single build, and the host keeps a fixed salt so a session there continues after
  a restart.
  """
  @spec put(Path.t()) :: :ok
  def put(data_dir \\ @data_dir) do
    endpoint = Application.get_env(:my_hi_fi, MyHiFiWeb.Endpoint, [])

    endpoint
    |> put_secret_key_base(data_dir)
    |> put_signing_salt(data_dir)
    |> then(&Application.put_env(:my_hi_fi, MyHiFiWeb.Endpoint, &1))
  end

  @doc """
  Read one value from the data partition, and write a new one if it holds none.
  """
  @sobelow_skip ["Traversal.FileModule"]
  @spec read_or_create(Path.t(), String.t(), pos_integer()) :: String.t()
  def read_or_create(data_dir, filename \\ @secret.filename, byte_count \\ @secret.byte_count) do
    path = Path.join(data_dir, filename)

    case File.read(path) do
      {:ok, value} -> value
      {:error, _reason} -> create(path, byte_count)
    end
  end

  defp put_secret_key_base(endpoint, data_dir) do
    case Keyword.get(endpoint, :secret_key_base) do
      nil ->
        Keyword.put(
          endpoint,
          :secret_key_base,
          read_or_create(data_dir, @secret.filename, @secret.byte_count)
        )

      _secret ->
        endpoint
    end
  end

  defp put_signing_salt(endpoint, data_dir) do
    live_view = Keyword.get(endpoint, :live_view, [])

    case Keyword.get(live_view, :signing_salt) do
      nil ->
        salt = read_or_create(data_dir, @salt.filename, @salt.byte_count)

        Keyword.put(endpoint, :live_view, Keyword.put(live_view, :signing_salt, salt))

      _salt ->
        endpoint
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp create(path, byte_count) do
    value = byte_count |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false)

    File.mkdir_p(Path.dirname(path))
    # If the write fails, a signed cookie and a LiveView session are not valid
    # after a restart. The device must still play music, so it continues with this
    # value.
    File.write(path, value)

    value
  end
end
