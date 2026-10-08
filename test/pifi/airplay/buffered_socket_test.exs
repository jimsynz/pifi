defmodule PiFi.AirPlay.BufferedSocketTest do
  @moduledoc """
  The TCP side of a buffered session, against blocks built the way a telephone builds
  them.

  `PiFi.AirPlay.AudioSocketTest` does the same for a realtime session. The sealing is
  the same in both, so the fixture here is the one that module uses, with the length in
  front of it and no datagram around it.
  """

  use ExUnit.Case, async: true

  alias PiFi.AirPlay.BufferedSocket
  alias PiFi.Player.AdtsFrame

  @frame "an aac frame, or near enough for a cipher"

  defp socket(options \\ []) do
    key = :crypto.strong_rand_bytes(32)

    {:ok, socket} = start_supervised({BufferedSocket, Keyword.merge([key: key], options)})
    {:ok, port} = BufferedSocket.port(socket)

    %{socket: socket, key: key, port: port}
  end

  defp connect(port) do
    {:ok, sender} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2000)

    on_exit(fn -> :gen_tcp.close(sender) end)

    sender
  end

  # The packet a sender sends: an RTP header, the audio sealed under the session key,
  # and the eight bytes of nonce at the end of it. See `PiFi.AirPlay.AudioPacket`.
  defp sealed(audio, key, sequence) do
    short = :crypto.strong_rand_bytes(8)
    timestamp = sequence * 1024
    ssrc = 0xDEADBEEF

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :chacha20_poly1305,
        key,
        <<0::32, short::binary>>,
        audio,
        <<timestamp::32, ssrc::32>>,
        true
      )

    <<2::2, 0::1, 0::1, 0::4, 0::1, 96::7, sequence::16, timestamp::32, ssrc::32,
      ciphertext::binary, tag::binary, short::binary>>
  end

  # **The length counts its own two bytes.** That is the one thing about this framing
  # that a reader cannot guess, and a receiver that counted only the packet would read
  # two bytes into the next block on every frame.
  defp block(packet), do: <<byte_size(packet) + 2::16, packet::binary>>

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

  defp arrived(socket, count) do
    eventually(fn -> BufferedSocket.statistics(socket).received >= count end)
  end

  describe "the port it binds" do
    test "it listens on the port it names" do
      %{port: port} = socket()

      assert {:ok, sender} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2000)

      :gen_tcp.close(sender)
    end
  end

  describe "a frame that a sender sent" do
    test "it comes back with an ADTS header in front of it" do
      %{socket: socket, key: key, port: port} = socket()
      sender = connect(port)

      :ok = :gen_tcp.send(sender, block(sealed(@frame, key, 0)))
      assert arrived(socket, 1)

      assert {:ok, %{payload: payload}} = BufferedSocket.take(socket)

      header = AdtsFrame.header(44_100, 2, byte_size(@frame))

      assert payload == header <> @frame
    end

    # TCP gives no message boundaries, so a read is as likely to hold half a block as a
    # whole one, and two blocks arrive together as readily as one.
    test "a block that arrives in pieces is still read" do
      %{socket: socket, key: key, port: port} = socket()
      sender = connect(port)

      whole = block(sealed(@frame, key, 0))

      for <<byte::binary-size(1) <- whole>> do
        :ok = :gen_tcp.send(sender, byte)
      end

      assert arrived(socket, 1)
      assert {:ok, _frame} = BufferedSocket.take(socket)
    end

    test "two blocks in one read both come back" do
      %{socket: socket, key: key, port: port} = socket()
      sender = connect(port)

      :ok =
        :gen_tcp.send(sender, block(sealed(@frame, key, 0)) <> block(sealed(@frame, key, 1)))

      assert arrived(socket, 2)

      assert {:ok, _first} = BufferedSocket.take(socket)
      assert {:ok, _second} = BufferedSocket.take(socket)
      assert :empty = BufferedSocket.take(socket)
    end

    test "the order they were sent in is the order they come back" do
      %{socket: socket, key: key, port: port} = socket()
      sender = connect(port)

      for sequence <- 0..9 do
        :ok = :gen_tcp.send(sender, block(sealed("frame #{sequence}", key, sequence)))
      end

      assert arrived(socket, 10)

      for sequence <- 0..9 do
        assert {:ok, %{payload: payload}} = BufferedSocket.take(socket)
        assert String.ends_with?(payload, "frame #{sequence}")
      end
    end

    # A frame sealed under another key is one this receiver cannot read. It is counted
    # and dropped, and the stream carries on.
    test "a frame under the wrong key is refused and not taken" do
      %{socket: socket, port: port} = socket()
      sender = connect(port)

      :ok = :gen_tcp.send(sender, block(sealed(@frame, :crypto.strong_rand_bytes(32), 0)))
      assert arrived(socket, 1)

      assert %{refused: 1, held: 0} = BufferedSocket.statistics(socket)
      assert :empty = BufferedSocket.take(socket)
    end
  end

  describe "nothing to take" do
    test "an empty socket says so rather than waiting" do
      %{socket: socket} = socket()

      assert :empty = BufferedSocket.take(socket)
    end
  end

  describe "the session ending" do
    # **The audio ending is the session ending.** `PiFi.AirPlay.Monitor` watches this
    # process, so stopping is what tells the player that the music is over.
    test "a sender that closes the connection stops this" do
      %{socket: socket, port: port} = socket()
      reference = Process.monitor(socket)

      sender = connect(port)
      :gen_tcp.close(sender)

      assert_receive {:DOWN, ^reference, :process, ^socket, :normal}, 2000
    end

    # A length that names nothing is a reader that has lost its place, and the next
    # block begins wherever this one was supposed to end.
    test "a block that names no bytes stops this" do
      %{socket: socket, port: port} = socket()
      reference = Process.monitor(socket)

      sender = connect(port)
      :ok = :gen_tcp.send(sender, <<0::16>>)

      assert_receive {:DOWN, ^reference, :process, ^socket, :normal}, 2000
    end
  end

  describe "a rate that ADTS cannot name" do
    # Every frame would otherwise be refused for the length of the session, with
    # nothing to say why.
    test "it refuses to start rather than refusing every frame" do
      Process.flag(:trap_exit, true)

      assert {:error, {:unnameable_rate, 44_101}} =
               BufferedSocket.start_link(key: :crypto.strong_rand_bytes(32), sample_rate: 44_101)
    end
  end
end
