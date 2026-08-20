defmodule MyHiFi.SecretKeyBase do
  @moduledoc """
  The endpoint secret for a device.

  A Nerves device has no environment variable that holds a secret. The firmware
  therefore keeps a secret on the application data partition.
  `MyHiFi.Application` calls `put/1` before it starts the endpoint.
  """

  # The data directory comes from the module attribute or from a test. It never
  # comes from a request. The traversal findings on this module are therefore not
  # correct. Sobelow reads @sobelow_skip from the source. This registration stops
  # the compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @data_dir "/root"
  @filename "secret_key_base"
  @byte_count 48

  @doc """
  Give the endpoint a secret, unless it already has one.

  A secret from `config/runtime.exs` has priority. `SECRET_KEY_BASE` in the
  environment is the manual method for a test or for a single build.
  """
  @spec put(Path.t()) :: :ok
  def put(data_dir \\ @data_dir) do
    endpoint = Application.get_env(:my_hi_fi, MyHiFiWeb.Endpoint, [])

    case Keyword.get(endpoint, :secret_key_base) do
      nil ->
        secret = read_or_create(data_dir)

        Application.put_env(
          :my_hi_fi,
          MyHiFiWeb.Endpoint,
          Keyword.put(endpoint, :secret_key_base, secret)
        )

      _secret ->
        :ok
    end
  end

  @doc """
  Read the secret from the data partition, and write a new one if it holds none.
  """
  @sobelow_skip ["Traversal.FileModule"]
  @spec read_or_create(Path.t()) :: String.t()
  def read_or_create(data_dir) do
    path = Path.join(data_dir, @filename)

    case File.read(path) do
      {:ok, secret} -> secret
      {:error, _reason} -> create(path)
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp create(path) do
    secret = @byte_count |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false)

    File.mkdir_p(Path.dirname(path))
    # If the write fails, the signed cookies are not valid after a restart. The
    # device must still play music, so it continues with this secret.
    File.write(path, secret)

    secret
  end
end
