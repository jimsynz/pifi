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

  test "decode! raises rather than returning an error" do
    assert_raise ArgumentError, fn -> BinaryPlist.decode!("not a plist") end
  end
end
