defmodule PiFi.AirPlay.ParametersTest do
  use ExUnit.Case, async: true

  alias PiFi.AirPlay.Parameters

  doctest PiFi.AirPlay.Parameters

  describe "the volume a sender asks for" do
    # The body a telephone at 192.168.5.50 sent on 2026-10-08.
    test "it reads the body a telephone sends" do
      assert {:ok, {:volume, 20}} = Parameters.read("volume: -24.000000\r\n")
    end

    test "the ends of the range are the ends of the percentage" do
      assert {:ok, {:volume, 100}} = Parameters.read("volume: 0.000000\r\n")
      assert {:ok, {:volume, 0}} = Parameters.read("volume: -30.000000\r\n")
    end

    # **Mute is a value of its own and not the bottom of the range.** Scaled with the
    # rest of it, -144 works out at about -380%, which is not a level at all.
    test "mute is silence and not a negative level" do
      assert {:ok, {:volume, 0}} = Parameters.read("volume: -144.000000\r\n")
    end

    # A sender sends more than one parameter in a body, and the volume is not always
    # the first line of it.
    test "it finds the volume among other parameters" do
      body = "progress: 1/2/3\r\nvolume: -15.000000\r\n"

      assert {:ok, {:volume, 50}} = Parameters.read(body)
    end
  end

  describe "a body with no volume in it" do
    test "the progress of a track is counted here and not taken from a sender" do
      assert :ignore = Parameters.read("progress: 1/2/3\r\n")
    end

    test "an empty body asks for nothing" do
      assert :ignore = Parameters.read("")
    end

    # A body of another kind reaches here as well: a picture arrives as `image/jpeg`
    # on a receiver that asks for the AirPlay 1 metadata, and it is not text at all.
    test "bytes that are not parameters ask for nothing" do
      assert :ignore = Parameters.read(<<0xFF, 0xD8, 0xFF, 0xE0>>)
    end

    test "a volume that names no number asks for nothing" do
      assert :ignore = Parameters.read("volume: loud\r\n")
    end
  end
end
