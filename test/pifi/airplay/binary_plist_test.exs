defmodule PiFi.AirPlay.BinaryPlistTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.BinaryPlist

  alias PiFi.AirPlay.BinaryPlist

  # **These came out of Python's `plistlib`, not out of my reading of the format.** A
  # parser tested against fixtures its own author invented tests the author's
  # understanding twice and the format never.
  @fixtures %{
    empty_dict: "YnBsaXN0MDDQCAAAAAAAAAEBAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAJ",
    simple:
      "YnBsaXN0MDDSAQIDBFRuYW1lVHBvcnRUUGlGaREbWAgNEhccAAAAAAAAAQEAAAAAAAAABQAAAAAAAAAAAAAAAAAAAB8=",
    nested:
      "YnBsaXN0MDDSAQIDCVFhVGZsYWfRBAVRYqMGBwgQARACEAMJCA0PFBcZHR8hIwAAAAAAAAEBAAAAAAAAAAoAAAAAAAAAAAAAAAAAAAAk",
    types:
      "YnBsaXN0MDDXAQIDBAUGBwgJCgsMDQ5RZFFmUmYyUWlTbmVnUXNRdEMBAgMjP/gAAAAAAAAIECoT//////////lVaGVsbG8JCBcZGx4gJCYoLDU2OEFHAAAAAAAAAQEAAAAAAAAADwAAAAAAAAAAAAAAAAAAAEg=",
    unicode:
      "YnBsaXN0MDDRAQJRa2YAYwBhAGYA6QAgALUICw0AAAAAAAABAQAAAAAAAAADAAAAAAAAAAAAAAAAAAAAGg==",
    array_top: "YnBsaXN0MDCjAQIDEAFTdHdvCAgMDhIAAAAAAAABAQAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAEw=="
  }

  defp fixture(name), do: @fixtures |> Map.fetch!(name) |> Base.decode64!()

  describe "reading what Apple's own writer produces" do
    test "an empty dictionary" do
      assert {:ok, %{}} = BinaryPlist.decode(fixture(:empty_dict))
    end

    test "strings and integers" do
      assert {:ok, %{"name" => "PiFi", "port" => 7000}} = BinaryPlist.decode(fixture(:simple))
    end

    # A container holds references and not values, so this is the one that proves the
    # offset table is being read rather than the bytes being walked.
    test "a dictionary inside a dictionary, and an array inside that" do
      assert {:ok, %{"a" => %{"b" => [1, 2, 3]}, "flag" => true}} =
               BinaryPlist.decode(fixture(:nested))
    end

    test "an array at the top rather than a dictionary" do
      assert {:ok, [1, "two", false]} = BinaryPlist.decode(fixture(:array_top))
    end

    test "every type that AirPlay uses" do
      assert {:ok, value} = BinaryPlist.decode(fixture(:types))

      assert value["i"] == 42
      assert value["s"] == "hello"
      assert value["t"] == true
      assert value["f2"] == false
      assert value["f"] == 1.5
      assert value["d"] == <<1, 2, 3>>
    end

    # **A negative integer is eight bytes and signed**, and the shorter ones are not.
    # Reading the wrong one gives 18446744073709551609 rather than -7.
    test "a negative integer" do
      assert {:ok, %{"neg" => -7}} = BinaryPlist.decode(fixture(:types))
    end

    # A UTF-16 string counts characters and not bytes, so a reader that takes the count
    # as a byte length returns half a string.
    test "a string that is not ASCII" do
      assert {:ok, %{"k" => "café µ"}} = BinaryPlist.decode(fixture(:unicode))
    end
  end

  # **This reads what arrives on a socket.** Every one of these is a message somebody
  # could send, and none of them may take the receiver down.
  describe "what it refuses" do
    test "something that is not a plist at all" do
      assert {:error, :not_a_binary_plist} = BinaryPlist.decode("<?xml version=\"1.0\"?>")
    end

    test "the header and nothing else" do
      assert {:error, :not_a_binary_plist} = BinaryPlist.decode("bplist00")
    end

    test "an empty message" do
      assert {:error, :not_a_binary_plist} = BinaryPlist.decode("")
    end

    # A trailer names the sizes, and a damaged one names impossible ones. Reading a
    # table of four thousand million entries out of two hundred bytes is how a parser
    # turns a bad packet into an outage.
    test "a trailer that claims more objects than the message can hold" do
      whole = fixture(:simple)
      body_size = byte_size(whole) - 32
      <<body::binary-size(^body_size), trailer::binary-size(32)>> = whole

      <<head::binary-size(8), _count::big-64, rest::binary>> = trailer
      damaged = body <> head <> <<4_000_000_000::big-64>> <> rest

      assert {:error, _reason} = BinaryPlist.decode(damaged)
    end

    test "a truncated message" do
      whole = fixture(:nested)
      assert {:error, _reason} = BinaryPlist.decode(binary_part(whole, 0, byte_size(whole) - 8))
    end
  end

  describe "writing a plist" do
    # **This was read back by Python's `plistlib` before it was pasted here.** An encoder
    # checked only against its own decoder agrees with itself and with nothing else.
    test "produces bytes Apple's own reader accepts" do
      written =
        BinaryPlist.encode(%{
          "features" => 1_548_492_136_448,
          "name" => "Kitchen",
          "pk" => {:data, <<1, 2, 3, 255>>},
          "vv" => 2
        })

      assert Base.encode64(written) ==
               "YnBsaXN0MDDUAQIDBAUGBwhYZmVhdHVyZXNUbmFtZVJwa1J2dhMAAAFoiVLgAFdLaXRjaGVuRAECA" <>
                 "/8QAggRGh8iJS42OwAAAAAAAAEBAAAAAAAAAAkAAAAAAAAAAAAAAAAAAAA9"
    end

    test "starts with the magic and ends with a trailer of thirty-two bytes" do
      written = BinaryPlist.encode(%{"a" => 1})

      assert <<"bplist00", _rest::binary>> = written

      <<_unused::binary-size(5), _sort, offset_size, reference_size, count::big-64, top::big-64,
        table_at::big-64>> = binary_part(written, byte_size(written) - 32, 32)

      assert offset_size in 1..8
      assert reference_size in 1..8
      assert top == 0
      assert table_at + count * offset_size <= byte_size(written)
    end

    test "round trips every type this firmware uses" do
      for value <- [
            nil,
            true,
            false,
            0,
            1,
            255,
            256,
            65_535,
            65_536,
            0xFFFFFFFF,
            0x100000000,
            -1,
            -9_000_000_000,
            -12.5,
            0.0,
            "",
            "Kitchen",
            String.duplicate("x", 40),
            "Küche — 台所",
            [],
            [1, "two", [3]],
            %{},
            %{"a" => %{"b" => [1, 2]}}
          ] do
        assert BinaryPlist.decode(BinaryPlist.encode(value)) == {:ok, value},
               "#{inspect(value)} did not survive"
      end
    end

    # A length of fifteen or more does not fit in the low nibble, and an integer object
    # carries it instead. The boundary is where that switches over.
    test "writes a length that does not fit in the nibble" do
      for length <- [0, 1, 13, 14, 15, 16, 300, 70_000] do
        text = String.duplicate("a", length)

        assert BinaryPlist.decode(BinaryPlist.encode(text)) == {:ok, text}

        assert BinaryPlist.decode(BinaryPlist.encode(List.duplicate(1, length))) ==
                 {:ok, List.duplicate(1, length)}
      end
    end

    test "writes tagged bytes as data and a plain binary as text" do
      assert {:ok, %{"k" => <<0, 1, 2>>}} =
               BinaryPlist.decode(BinaryPlist.encode(%{"k" => {:data, <<0, 1, 2>>}}))

      assert {:ok, %{"k" => "abc"}} = BinaryPlist.decode(BinaryPlist.encode(%{"k" => "abc"}))
    end

    # Thirty-two random bytes are valid UTF-8 often enough to pass a test and fail on a
    # board, which is why data is tagged rather than guessed at.
    test "writes a key that happens to be valid text as data when it is tagged" do
      key = :crypto.strong_rand_bytes(32)

      assert {:ok, %{"pk" => ^key}} =
               BinaryPlist.decode(BinaryPlist.encode(%{"pk" => {:data, key}}))
    end

    test "gives the same bytes for the same content, whatever order the keys arrived in" do
      one = BinaryPlist.encode(%{"a" => 1, "b" => 2, "c" => 3})
      other = BinaryPlist.encode(%{"c" => 3, "b" => 2, "a" => 1})

      assert one == other
    end

    test "keeps a date to the second" do
      when_ = DateTime.from_unix!(1_600_000_000)

      assert {:ok, ^when_} = BinaryPlist.decode(BinaryPlist.encode(when_))
    end

    test "refuses a value the format cannot hold" do
      assert_raise ArgumentError, fn -> BinaryPlist.encode({:a, :b, :c}) end
      assert_raise ArgumentError, fn -> BinaryPlist.encode(self()) end
      assert_raise ArgumentError, fn -> BinaryPlist.encode(0x8000000000000000) end
    end
  end

  describe "writing back what Apple's writer produced" do
    # Every fixture above came out of `plistlib`. Reading one, writing it again and
    # reading that must give the same value, which ties the encoder to real data rather
    # than to my reading of the format.
    for name <- [:empty_dict, :simple, :nested, :array_top, :unicode] do
      test "#{name} survives a decode, an encode and a decode" do
        value = BinaryPlist.decode!(fixture(unquote(name)))

        assert BinaryPlist.decode(BinaryPlist.encode(value)) == {:ok, value}
      end
    end
  end

  test "decode! raises rather than returning an error" do
    assert_raise ArgumentError, fn -> BinaryPlist.decode!("not a plist") end
  end
end
