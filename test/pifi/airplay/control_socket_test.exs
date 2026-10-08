defmodule PiFi.AirPlay.ControlSocketTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.ControlSocket

  alias PiFi.AirPlay.ControlSocket

  # A reply carries the original datagram after four bytes of its own header.
  defp reply(inner), do: <<0x80, 0xD6, 0::16>> <> inner

  defp timing, do: <<0x80, 0xD4, 1::16, 0::32, 0::64>>

  defp sending(socket, datagram) do
    {:ok, port} = ControlSocket.port(socket)
    {:ok, sender} = :gen_udp.open(0, [:binary, active: false])

    :ok = :gen_udp.send(sender, {127, 0, 0, 1}, port, datagram)

    sender
  end

  defp eventually(check, attempts \\ 100)

  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end

  describe "the eight bytes that ask for a run" do
    test "it names where to start and how many" do
      assert <<_version::2, _padding::1, _extension::1, _csrcs::4, 1::1, 0x55::7, 1::16, 1234::16,
               5::16>> = ControlSocket.ask(1234, 5)
    end

    # Sixteen bits wrap, so a request near the top of the range is a number like any
    # other and the sender does the arithmetic.
    test "a sequence near the wrap is sent as it is" do
      assert <<_head::binary-size(4), 65_535::16, 2::16>> = ControlSocket.ask(65_535, 2)
    end
  end

  describe "what comes back" do
    test "a reply gives up the packet inside it" do
      assert {:ok, "the original packet"} = ControlSocket.inner(reply("the original packet"))
    end

    # **A timing packet is not a reply**, and reading one as a reply would hand the
    # audio socket four bytes of header and a clock.
    test "a timing packet is not one" do
      assert ControlSocket.inner(timing()) == :error
    end

    test "a datagram with nothing after the header is not one" do
      assert ControlSocket.inner(<<0x80, 0xD6, 0::16>>) == :error
    end

    test "anything at all is not one" do
      assert ControlSocket.inner(<<>>) == :error
      assert ControlSocket.inner("not rtp at all") == :error
    end
  end

  describe "the socket" do
    setup do
      socket = start_supervised!({ControlSocket, []})

      %{socket: socket}
    end

    test "it binds a port the answer to SETUP can name", %{socket: socket} do
      assert {:ok, port} = ControlSocket.port(socket)
      assert port > 0
    end

    # **Nothing is asked for until something has arrived**, because nothing knows where
    # to send until then.
    test "it asks for nothing before it has heard from a sender", %{socket: socket} do
      ControlSocket.request(socket, 7, 3)

      assert %{asked: 0} = ControlSocket.statistics(socket)
    end

    test "it learns where to send from the first packet to arrive", %{socket: socket} do
      sender = sending(socket, timing())

      assert eventually(fn -> ControlSocket.statistics(socket).ignored > 0 end)

      ControlSocket.request(socket, 7, 3)

      assert eventually(fn -> ControlSocket.statistics(socket).asked == 3 end)
      assert {:ok, {_address, _port, asked}} = :gen_udp.recv(sender, 0, 1_000)
      assert IO.iodata_to_binary(asked) == ControlSocket.ask(7, 3)
    end

    # A session of remote control alone has no audio socket, so a reply has nowhere to
    # go and must not take the process with it.
    test "a reply with no audio socket is counted and dropped", %{socket: socket} do
      sending(socket, reply("packet"))

      assert eventually(fn -> ControlSocket.statistics(socket).ignored > 0 end)
      assert Process.alive?(socket)
    end
  end

  test "a reply reaches the audio socket that was named" do
    socket = start_supervised!({ControlSocket, []})
    ControlSocket.audio(socket, self())

    sending(socket, reply("the original packet"))

    assert eventually(fn -> ControlSocket.statistics(socket).answered > 0 end)
    assert_received {:"$gen_cast", {:deliver, "the original packet"}}
  end
end
