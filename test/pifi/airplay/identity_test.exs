defmodule PiFi.AirPlay.IdentityTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.Identity

  alias PiFi.AirPlay.Identity

  setup do
    dir = Path.join(System.tmp_dir!(), "airplay-identity-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir}
  end

  describe "the key that outlives a reboot" do
    # **A telephone pairs once and verifies on every connection afterwards.** A key that
    # changed would make every paired telephone refuse this device until somebody
    # removed the accessory and paired again.
    test "asking twice gives the same key", %{dir: dir} do
      assert Identity.pair(dir) == Identity.pair(dir)
    end

    test "it survives the process that made it", %{dir: dir} do
      first = Identity.public_key(dir)

      # A second read with nothing cached is what a reboot looks like from here.
      assert Identity.public_key(dir) == first
    end

    test "two devices have different identities", %{dir: dir} do
      other = dir <> "-other"
      on_exit(fn -> File.rm_rf(other) end)

      refute Identity.public_key(dir) == Identity.public_key(other)
    end

    test "the keys are the sizes Ed25519 uses", %{dir: dir} do
      pair = Identity.pair(dir)

      assert byte_size(pair.public) == 32
      assert byte_size(pair.private) == 32
    end
  end

  # Only the seed is kept, and the pair is derived. A file holding the public key as
  # well would be a second copy of something already implied, and the two could
  # disagree.
  describe "the file" do
    test "it holds the seed and nothing else", %{dir: dir} do
      Identity.pair(dir)

      assert {:ok, contents} = File.read(Path.join(dir, Identity.filename()))
      assert byte_size(contents) == 32
    end

    test "the seed in the file is what the pair derives from", %{dir: dir} do
      pair = Identity.pair(dir)
      seed = File.read!(Path.join(dir, Identity.filename()))

      assert Identity.from_seed(seed) == pair
    end
  end

  describe "signing" do
    test "what it signs, it verifies", %{dir: dir} do
      message = "the message"
      signature = Identity.sign(message, dir)

      assert Identity.verify(message, signature, Identity.public_key(dir))
    end

    test "a signature over something else does not verify", %{dir: dir} do
      signature = Identity.sign("one thing", dir)

      refute Identity.verify("another thing", signature, Identity.public_key(dir))
    end

    test "a signature from another device does not verify", %{dir: dir} do
      other = dir <> "-other"
      on_exit(fn -> File.rm_rf(other) end)

      signature = Identity.sign("the message", other)

      refute Identity.verify("the message", signature, Identity.public_key(dir))
    end

    # **A signature that does not check is a telephone that is not what it says**, which
    # is a connection to refuse rather than a fault to raise about.
    test "rubbish in place of a signature answers rather than raising", %{dir: dir} do
      refute Identity.verify("the message", "not a signature", Identity.public_key(dir))
    end

    test "rubbish in place of a public key answers rather than raising" do
      refute Identity.verify("the message", :binary.copy(<<0>>, 64), "not a key")
    end
  end
end
