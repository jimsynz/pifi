defmodule PiFi.AirPlay.Identity do
  @moduledoc """
  The long-term key that says this receiver is the same one as last time.

  A telephone pairs once and verifies on every connection afterwards. What it checks is
  an Ed25519 signature from a key this device keeps, so **the key has to outlive a
  reboot or every paired telephone would have to pair again**.

  It goes on the writable partition beside the endpoint secret, for the reasons
  `PiFi.DeviceSecrets` gives: a Nerves device has no environment to hold a secret, and
  `/root` is the only writable storage.

  ## Only the seed is kept

  Ed25519 derives its key pair from 32 bytes, and `:crypto.generate_key/3` is
  deterministic given them, so the file holds the seed and the pair is derived when it
  is wanted. A file holding a public key as well would be a second copy of something
  already implied, and the two could disagree.

  ## Losing it is losing every pairing

  A device that lost this file would present a different identity and every telephone
  would refuse it until a person removed the accessory and paired again. That is the
  correct behaviour — a receiver that could change identity without anybody noticing is
  one that could be swapped for another — but it is worth knowing before anybody writes
  something that removes files from `/root`.
  """

  # Sobelow reads `@sobelow_skip` from the source. This registration stops the compiler
  # warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @data_dir "/root"
  @filename "airplay_identity"
  @seed_bytes 32

  @typedoc "An Ed25519 key pair, as `:crypto` gives them."
  @type pair :: %{public: <<_::256>>, private: <<_::256>>}

  @doc """
  The file that holds the seed.

      iex> PiFi.AirPlay.Identity.filename()
      "airplay_identity"
  """
  @spec filename() :: String.t()
  def filename, do: @filename

  @doc """
  The key pair of this device, made on the first call and kept afterwards.
  """
  @spec pair(Path.t()) :: pair()
  def pair(data_dir \\ @data_dir) do
    data_dir |> seed() |> from_seed()
  end

  @doc """
  The public key, which is what a telephone remembers about this device.
  """
  @spec public_key(Path.t()) :: <<_::256>>
  def public_key(data_dir \\ @data_dir), do: pair(data_dir).public

  @doc """
  Derive a pair from a seed, without reading or writing anything.

  It is deterministic, which is what lets the file hold the seed alone.

      iex> seed = :binary.copy(<<7>>, 32)
      iex> PiFi.AirPlay.Identity.from_seed(seed) == PiFi.AirPlay.Identity.from_seed(seed)
      true
  """
  @spec from_seed(<<_::256>>) :: pair()
  def from_seed(seed) when byte_size(seed) == @seed_bytes do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519, seed)

    %{public: public, private: private}
  end

  @doc """
  Sign something as this device.
  """
  @spec sign(binary(), Path.t()) :: binary()
  def sign(message, data_dir \\ @data_dir) do
    :crypto.sign(:eddsa, :none, message, [pair(data_dir).private, :ed25519])
  end

  @doc """
  Check a signature against a public key that a telephone sent.

  **It answers rather than raising.** A signature that does not check is a telephone
  that is not the one it says it is, which is a connection to refuse and not a fault.
  """
  @spec verify(binary(), binary(), <<_::256>>) :: boolean()
  def verify(message, signature, public_key) do
    :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  rescue
    _error -> false
  end

  # The path comes from a constant and a caller that names its own directory is a test.
  @sobelow_skip ["Traversal.FileModule"]
  defp seed(data_dir) do
    path = Path.join(data_dir, @filename)

    case File.read(path) do
      {:ok, <<seed::binary-size(@seed_bytes)>>} ->
        seed

      _other ->
        created = :crypto.strong_rand_bytes(@seed_bytes)

        File.mkdir_p!(data_dir)
        File.write!(path, created)

        created
    end
  end
end
