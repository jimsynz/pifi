defmodule MyHiFi.SecretKeyBaseTest do
  use ExUnit.Case, async: true

  alias MyHiFi.SecretKeyBase

  setup do
    data_dir = Path.join(System.tmp_dir!(), "my_hi_fi-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(data_dir) end)
    {:ok, data_dir: data_dir}
  end

  describe "read_or_create/1" do
    test "writes a secret when the partition holds none", %{data_dir: data_dir} do
      secret = SecretKeyBase.read_or_create(data_dir)

      assert byte_size(secret) == 64
      assert File.read!(Path.join(data_dir, "secret_key_base")) == secret
    end

    test "returns the same secret on the next boot", %{data_dir: data_dir} do
      assert SecretKeyBase.read_or_create(data_dir) == SecretKeyBase.read_or_create(data_dir)
    end

    test "returns a secret when it cannot write" do
      assert byte_size(SecretKeyBase.read_or_create("/proc/no-such-place")) == 64
    end
  end

  describe "put/1" do
    test "keeps a secret that the configuration already gives", %{data_dir: data_dir} do
      configured = Application.get_env(:my_hi_fi, MyHiFiWeb.Endpoint)[:secret_key_base]

      assert :ok = SecretKeyBase.put(data_dir)

      assert Application.get_env(:my_hi_fi, MyHiFiWeb.Endpoint)[:secret_key_base] == configured
      refute File.exists?(Path.join(data_dir, "secret_key_base"))
    end
  end
end
