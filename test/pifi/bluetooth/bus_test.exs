defmodule PiFi.Bluetooth.BusTest do
  use ExUnit.Case, async: true

  doctest PiFi.Bluetooth.Bus

  alias PiFi.Bluetooth.Bus

  # **This is the whole of the EXTERNAL authentication**, and the library ships a
  # constant for uid 1000 while a Nerves device runs as root. A board reported the
  # mismatch as a connection that hung and said nothing about why.
  describe "the cookie that the bus checks" do
    test "root is the one that matters here" do
      assert Bus.external_cookie(0) == "30"
    end

    test "it is the decimal uid as text, hex encoded" do
      for uid <- [0, 1, 42, 1000, 65_534] do
        assert Bus.external_cookie(uid) == Base.encode16(to_string(uid), case: :lower)
      end
    end

    # The library's own constant, written down rather than remembered.
    test "1000 is the constant the library ships" do
      assert Bus.external_cookie(1000) == "31303030"
    end
  end

  describe "the uid it reads" do
    test "it is a number on any machine that runs this suite" do
      assert is_integer(Bus.uid())
      assert Bus.uid() >= 0
    end

    # The whole point is that it reads rather than assumes, so on a laptop it must
    # report the laptop's uid and not root.
    test "it agrees with the system" do
      {output, 0} = System.cmd("id", ["-u"])

      assert Bus.uid() == output |> String.trim() |> String.to_integer()
    end
  end

  # A laptop runs no system bus, and everything above this has its tests there.
  test "asking a bus that is not there gives an answer rather than raising" do
    refute Bus.connected?()
  end

  # **The library calls its debug logging `?debug` and sends it at info**, so every
  # method and every reply lands in a log that holds 1024 lines. A board did something
  # interesting and the buffer held nothing but D-Bus traffic.
  describe "the filter that quietens the library" do
    test "drops a legacy informational report" do
      event = %{level: :info, msg: {:string, "Calling"}, meta: %{error_logger: %{tag: :info_msg}}}

      assert Bus.drop_legacy_info(event, []) == :stop
    end

    # These are what said the authentication failed and what found a namespace bug.
    test "keeps a warning and an error from the same library" do
      for tag <- [:warning_msg, :error_msg] do
        event = %{level: :warning, msg: {:string, "x"}, meta: %{error_logger: %{tag: tag}}}

        assert Bus.drop_legacy_info(event, []) == :ignore
      end
    end

    test "keeps everything that is not a legacy report at all" do
      assert Bus.drop_legacy_info(%{level: :info, msg: {:string, "x"}, meta: %{}}, []) == :ignore
    end
  end
end
