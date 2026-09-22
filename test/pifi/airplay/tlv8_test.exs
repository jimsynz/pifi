defmodule PiFi.AirPlay.Tlv8Test do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.Tlv8

  alias PiFi.AirPlay.Tlv8

  describe "reading" do
    test "an empty message holds nothing" do
      assert {:ok, []} = Tlv8.decode(<<>>)
    end

    test "a zero-length item is a value of no bytes and not an absence" do
      assert {:ok, [{0xFF, ""}]} = Tlv8.decode(<<0xFF, 0x00>>)
    end

    # **A length is one byte, so a long value is split**, and the pieces are one value.
    test "consecutive items of one type join" do
      message = <<0x03, 0x02, "ab", 0x03, 0x02, "cd">>

      assert {:ok, [{0x03, "abcd"}]} = Tlv8.decode(message)
    end

    # Two of a type with something between them are two values, which is how a message
    # carries more than one certificate.
    test "items of one type with something between them stay apart" do
      message = <<0x03, 0x01, "a", 0xFF, 0x00, 0x03, 0x01, "b">>

      assert {:ok, [{0x03, "a"}, {0xFF, ""}, {0x03, "b"}]} = Tlv8.decode(message)
    end

    test "the order is kept" do
      message = <<0x06, 0x01, 0x01, 0x01, 0x01, "a", 0x06, 0x01, 0x02>>

      assert {:ok, [{0x06, <<0x01>>}, {0x01, "a"}, {0x06, <<0x02>>}]} = Tlv8.decode(message)
    end

    test "a message that runs out mid-item is an error" do
      assert {:error, :truncated} = Tlv8.decode(<<0x06, 0x04, 0x01, 0x02>>)
    end

    test "a message that ends on a type with no length is an error" do
      assert {:error, :truncated} = Tlv8.decode(<<0x06>>)
    end
  end

  describe "writing" do
    test "a value of no bytes still writes its type" do
      assert Tlv8.encode([{0xFF, ""}]) == <<0xFF, 0x00>>
    end

    # The round trip is the real check: a writer and a reader that agree on a mistake
    # would both pass a test of either one alone.
    test "everything written reads back the same" do
      for size <- [0, 1, 254, 255, 256, 300, 511, 512, 1000] do
        value = :crypto.strong_rand_bytes(size)

        assert {:ok, [{0x03, ^value}]} =
                 value |> then(&Tlv8.encode([{0x03, &1}])) |> Tlv8.decode()
      end
    end

    test "a message of several types reads back in order" do
      items = [{0x06, <<0x03>>}, {0x03, :crypto.strong_rand_bytes(400)}, {0x05, "state"}]

      assert {:ok, ^items} = items |> Tlv8.encode() |> Tlv8.decode()
    end

    # **A value of exactly 255 is the boundary case**, because a reader cannot tell a
    # full fragment from a value that happens to be that long without the empty one
    # that follows.
    test "a value of exactly 255 bytes survives" do
      value = :crypto.strong_rand_bytes(255)

      assert {:ok, [{0x01, ^value}]} = [{0x01, value}] |> Tlv8.encode() |> Tlv8.decode()
    end
  end

  describe "fetch" do
    test "it gives the first value of a type" do
      assert {:ok, "a"} = Tlv8.fetch([{0x03, "a"}, {0xFF, ""}, {0x03, "b"}], 0x03)
    end

    test "a type that is not there is an error and not nil" do
      assert :error = Tlv8.fetch([{0x03, "a"}], 0x09)
    end
  end
end
