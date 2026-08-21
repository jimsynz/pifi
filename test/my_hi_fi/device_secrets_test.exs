defmodule MyHiFi.DeviceSecretsTest do
  use ExUnit.Case, async: false

  alias MyHiFi.DeviceSecrets

  setup do
    data_dir = Path.join(System.tmp_dir!(), "my_hi_fi-#{System.unique_integer([:positive])}")
    endpoint = Application.get_env(:my_hi_fi, MyHiFiWeb.Endpoint, [])

    on_exit(fn ->
      File.rm_rf!(data_dir)
      Application.put_env(:my_hi_fi, MyHiFiWeb.Endpoint, endpoint)
    end)

    {:ok, data_dir: data_dir, endpoint: endpoint}
  end

  defp without(keys) do
    endpoint =
      Application.get_env(:my_hi_fi, MyHiFiWeb.Endpoint, [])
      |> Keyword.drop(keys)

    Application.put_env(:my_hi_fi, MyHiFiWeb.Endpoint, endpoint)
  end

  defp endpoint_config, do: Application.get_env(:my_hi_fi, MyHiFiWeb.Endpoint, [])

  describe "read_or_create/3" do
    test "writes a value when the partition holds none", %{data_dir: data_dir} do
      secret = DeviceSecrets.read_or_create(data_dir)

      assert byte_size(secret) == 64
      assert File.read!(Path.join(data_dir, "secret_key_base")) == secret
    end

    test "gives the same value on the next boot", %{data_dir: data_dir} do
      assert DeviceSecrets.read_or_create(data_dir) == DeviceSecrets.read_or_create(data_dir)
    end

    test "gives a value when it cannot write" do
      assert byte_size(DeviceSecrets.read_or_create("/proc/no-such-place")) == 64
    end

    test "each name holds its own value", %{data_dir: data_dir} do
      secret = DeviceSecrets.read_or_create(data_dir, "secret_key_base", 48)
      salt = DeviceSecrets.read_or_create(data_dir, "signing_salt", 16)

      refute secret == salt
      assert byte_size(salt) < byte_size(secret)
    end
  end

  describe "put/1" do
    test "gives the endpoint a secret and a salt", %{data_dir: data_dir} do
      without([:secret_key_base, :live_view])

      DeviceSecrets.put(data_dir)

      assert is_binary(endpoint_config()[:secret_key_base])
      assert is_binary(endpoint_config()[:live_view][:signing_salt])
    end

    test "keeps a secret that the configuration already gives", %{data_dir: data_dir} do
      Application.put_env(
        :my_hi_fi,
        MyHiFiWeb.Endpoint,
        Keyword.put(endpoint_config(), :secret_key_base, "a secret from the configuration")
      )

      DeviceSecrets.put(data_dir)

      assert endpoint_config()[:secret_key_base] == "a secret from the configuration"
      refute File.exists?(Path.join(data_dir, "secret_key_base"))
    end

    test "keeps a salt that the configuration already gives", %{data_dir: data_dir} do
      # A host holds a fixed salt, so a session there continues after a restart.
      Application.put_env(
        :my_hi_fi,
        MyHiFiWeb.Endpoint,
        Keyword.put(endpoint_config(), :live_view, signing_salt: "a salt from the configuration")
      )

      DeviceSecrets.put(data_dir)

      assert endpoint_config()[:live_view][:signing_salt] == "a salt from the configuration"
      refute File.exists?(Path.join(data_dir, "signing_salt"))
    end

    test "the salt stays the same across a restart, so a session continues",
         %{data_dir: data_dir} do
      without([:live_view])
      DeviceSecrets.put(data_dir)
      first = endpoint_config()[:live_view][:signing_salt]

      without([:live_view])
      DeviceSecrets.put(data_dir)

      assert endpoint_config()[:live_view][:signing_salt] == first
    end

    test "two devices hold two salts" do
      one = Path.join(System.tmp_dir!(), "device_one_#{System.unique_integer([:positive])}")
      two = Path.join(System.tmp_dir!(), "device_two_#{System.unique_integer([:positive])}")
      on_exit(fn -> Enum.each([one, two], &File.rm_rf!/1) end)

      refute DeviceSecrets.read_or_create(one, "signing_salt", 16) ==
               DeviceSecrets.read_or_create(two, "signing_salt", 16)
    end

    test "it keeps the other keys of the endpoint", %{data_dir: data_dir} do
      without([:secret_key_base, :live_view])

      DeviceSecrets.put(data_dir)

      assert endpoint_config()[:pubsub_server] == MyHiFi.PubSub
    end
  end
end
