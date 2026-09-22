defmodule PiFi.AirPlay.SecureChannelTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.SecureChannel

  alias PiFi.AirPlay.Hkdf
  alias PiFi.AirPlay.SecureChannel

  @tag_bytes 16

  defp keys do
    %{read: :crypto.strong_rand_bytes(32), write: :crypto.strong_rand_bytes(32)}
  end

  # **The two sides from one secret, each naming its keys its own way round.** The names
  # belong to the controller, so the accessory reads with what the controller writes.
  # Two channels built this way can talk; two built the same way round cannot.
  defp pair_of_channels do
    shared = :crypto.strong_rand_bytes(32)

    controller_writes =
      Hkdf.derive(:sha512, shared, "Control-Salt", "Control-Write-Encryption-Key", 32)

    controller_reads =
      Hkdf.derive(:sha512, shared, "Control-Salt", "Control-Read-Encryption-Key", 32)

    {
      SecureChannel.new(%{read: controller_reads, write: controller_writes}),
      SecureChannel.new(%{read: controller_writes, write: controller_reads})
    }
  end

  describe "the shape of a block" do
    test "is a little-endian length, the ciphertext, and a sixteen byte tag" do
      {sealed, _channel} = SecureChannel.seal(SecureChannel.new(keys()), "hello")

      assert <<length::little-16, rest::binary>> = sealed
      assert length == 5
      assert byte_size(rest) == 5 + @tag_bytes
    end

    test "something longer than a block goes in several" do
      plain = :binary.copy("x", 2500)
      {sealed, _channel} = SecureChannel.seal(SecureChannel.new(keys()), plain)

      # Three blocks: 1024, 1024, 452. Each carries two bytes of length and a tag.
      assert byte_size(sealed) == 2500 + 3 * (2 + @tag_bytes)

      assert <<first::little-16, _rest::binary>> = sealed
      assert first == SecureChannel.block_max()
    end

    test "exactly one block's worth is one block" do
      plain = :binary.copy("x", SecureChannel.block_max())
      {sealed, _channel} = SecureChannel.seal(SecureChannel.new(keys()), plain)

      assert byte_size(sealed) == SecureChannel.block_max() + 2 + @tag_bytes
    end

    test "nothing to send is nothing on the wire" do
      assert {<<>>, _channel} = SecureChannel.seal(SecureChannel.new(keys()), "")
    end
  end

  describe "two sides talking" do
    test "the accessory reads what the controller wrote" do
      {controller, accessory} = pair_of_channels()

      {sealed, _controller} = SecureChannel.seal(controller, "SETUP rtsp://host RTSP/1.0\r\n")

      assert {:ok, plain, "", _accessory} = SecureChannel.open(accessory, sealed)
      assert plain == "SETUP rtsp://host RTSP/1.0\r\n"
    end

    test "the controller reads what the accessory wrote" do
      {controller, accessory} = pair_of_channels()

      {sealed, _accessory} = SecureChannel.seal(accessory, "RTSP/1.0 200 OK\r\n")

      assert {:ok, "RTSP/1.0 200 OK\r\n", "", _controller} =
               SecureChannel.open(controller, sealed)
    end

    # This is the one that catches the keys being the same way round on both sides,
    # which is what an accessory naming them from the controller's point of view does.
    test "two channels built the same way round cannot talk" do
      shared = :crypto.strong_rand_bytes(32)

      one =
        SecureChannel.new(%{
          read: Hkdf.derive(:sha512, shared, "Control-Salt", "Control-Read-Encryption-Key", 32),
          write: Hkdf.derive(:sha512, shared, "Control-Salt", "Control-Write-Encryption-Key", 32)
        })

      other =
        SecureChannel.new(%{
          read: Hkdf.derive(:sha512, shared, "Control-Salt", "Control-Read-Encryption-Key", 32),
          write: Hkdf.derive(:sha512, shared, "Control-Salt", "Control-Write-Encryption-Key", 32)
        })

      {sealed, _one} = SecureChannel.seal(one, "hello")

      assert {:error, _reason} = SecureChannel.open(other, sealed)
    end

    test "a long message survives the split into blocks" do
      {controller, accessory} = pair_of_channels()
      plain = :crypto.strong_rand_bytes(5000)

      {sealed, _controller} = SecureChannel.seal(controller, plain)

      assert {:ok, ^plain, "", _accessory} = SecureChannel.open(accessory, sealed)
    end

    test "message after message, with the counters keeping step" do
      {controller, accessory} = pair_of_channels()

      Enum.reduce(1..20, {controller, accessory}, fn n, {controller, accessory} ->
        text = "message #{n}"
        {sealed, controller} = SecureChannel.seal(controller, text)

        assert {:ok, ^text, "", accessory} = SecureChannel.open(accessory, sealed)

        {controller, accessory}
      end)
    end
  end

  describe "the counters" do
    # Reusing a nonce with the same key is the one mistake ChaCha20-Poly1305 does not
    # survive, so the same plaintext must never give the same bytes twice.
    test "move on, so the same message twice is different on the wire" do
      channel = SecureChannel.new(keys())

      {first, channel} = SecureChannel.seal(channel, "same")
      {second, _channel} = SecureChannel.seal(channel, "same")

      refute first == second
    end

    test "count blocks and not messages" do
      channel = SecureChannel.new(keys())

      {_sealed, channel} = SecureChannel.seal(channel, :binary.copy("x", 2500))

      assert channel.write_counter == 3
    end

    test "reading and writing count separately" do
      {controller, accessory} = pair_of_channels()

      {sealed, _controller} = SecureChannel.seal(controller, "one")
      {:ok, _plain, "", accessory} = SecureChannel.open(accessory, sealed)

      assert accessory.read_counter == 1
      assert accessory.write_counter == 0
    end

    # The stream is a sequence. A reader that took the second message first would be
    # using the wrong nonce for it and for everything after.
    test "a message read out of order does not open" do
      {controller, accessory} = pair_of_channels()

      {_first, controller} = SecureChannel.seal(controller, "first")
      {second, _controller} = SecureChannel.seal(controller, "second")

      assert {:error, _reason} = SecureChannel.open(accessory, second)
    end
  end

  describe "reading what has arrived so far" do
    test "a block that is only half here is held for next time" do
      {controller, accessory} = pair_of_channels()
      {sealed, _controller} = SecureChannel.seal(controller, "a whole message")

      half = binary_part(sealed, 0, div(byte_size(sealed), 2))

      assert {:ok, "", ^half, accessory} = SecureChannel.open(accessory, half)

      rest = binary_part(sealed, byte_size(half), byte_size(sealed) - byte_size(half))

      assert {:ok, "a whole message", "", _accessory} =
               SecureChannel.open(accessory, half <> rest)
    end

    test "a length with nothing after it is held" do
      accessory = SecureChannel.new(keys())

      assert {:ok, "", <<5, 0>>, _accessory} = SecureChannel.open(accessory, <<5, 0>>)
    end

    test "one byte is held" do
      accessory = SecureChannel.new(keys())

      assert {:ok, "", <<7>>, _accessory} = SecureChannel.open(accessory, <<7>>)
    end

    test "nothing at all is nothing" do
      accessory = SecureChannel.new(keys())

      assert {:ok, "", "", _accessory} = SecureChannel.open(accessory, "")
    end

    test "several blocks in one read all come out" do
      {controller, accessory} = pair_of_channels()

      {one, controller} = SecureChannel.seal(controller, "first ")
      {two, controller} = SecureChannel.seal(controller, "second ")
      {three, _controller} = SecureChannel.seal(controller, "third")

      assert {:ok, "first second third", "", _accessory} =
               SecureChannel.open(accessory, one <> two <> three)
    end

    test "whole blocks come out and a partial one is held" do
      {controller, accessory} = pair_of_channels()

      {one, controller} = SecureChannel.seal(controller, "first")
      {two, _controller} = SecureChannel.seal(controller, "second")
      half = binary_part(two, 0, 4)

      assert {:ok, "first", ^half, _accessory} = SecureChannel.open(accessory, one <> half)
    end
  end

  describe "what it refuses" do
    test "a tag that does not check" do
      {controller, accessory} = pair_of_channels()
      {sealed, _controller} = SecureChannel.seal(controller, "hello")

      last = byte_size(sealed) - 1
      <<head::binary-size(^last), final>> = sealed
      tampered = head <> <<Bitwise.bxor(final, 1)>>

      assert {:error, _reason} = SecureChannel.open(accessory, tampered)
    end

    test "a message whose bytes were changed" do
      {controller, accessory} = pair_of_channels()
      {sealed, _controller} = SecureChannel.seal(controller, "hello")

      <<length::little-16, first, rest::binary>> = sealed
      tampered = <<length::little-16, Bitwise.bxor(first, 0xFF), rest::binary>>

      assert {:error, _reason} = SecureChannel.open(accessory, tampered)
    end

    # The length is the associated data, so changing it breaks the tag. Without that,
    # somebody could change how much of the stream got read.
    test "a length that says something other than what was sent" do
      {controller, accessory} = pair_of_channels()
      {sealed, _controller} = SecureChannel.seal(controller, :binary.copy("x", 40))

      <<_length::little-16, rest::binary>> = sealed
      tampered = <<39::little-16, rest::binary>>

      assert {:error, _reason} = SecureChannel.open(accessory, tampered)
    end

    # Without this, plaintext sent to an encrypted channel reads as a length of some tens
    # of thousands and the connection waits for bytes that are never coming, holding
    # whatever arrives in the meantime.
    test "a length longer than a block can be" do
      accessory = SecureChannel.new(keys())

      assert {:error, {:block_too_long, _length}} =
               SecureChannel.open(accessory, "GET /info RTSP/1.0\r\n\r\n")
    end

    test "the largest a block may be is still read" do
      {controller, accessory} = pair_of_channels()
      plain = :binary.copy("x", SecureChannel.block_max())

      {sealed, _controller} = SecureChannel.seal(controller, plain)

      assert {:ok, ^plain, "", _accessory} = SecureChannel.open(accessory, sealed)
    end

    test "one byte more than a block is refused" do
      accessory = SecureChannel.new(keys())
      too_long = SecureChannel.block_max() + 1

      assert {:error, {:block_too_long, ^too_long}} =
               SecureChannel.open(accessory, <<too_long::little-16>> <> :binary.copy("x", 2000))
    end

    test "a block sealed with somebody else's key" do
      {_controller, accessory} = pair_of_channels()
      {sealed, _other} = SecureChannel.seal(SecureChannel.new(keys()), "hello")

      assert {:error, _reason} = SecureChannel.open(accessory, sealed)
    end
  end
end
