defmodule PiFi.AirPlay.AudioSocketTest do
  @moduledoc """
  The socket that takes AirPlay audio, over a real UDP socket.

  **These send actual datagrams to a real port on the loopback address.** A test that
  called `handle_info/2` directly would pass with a socket that was never opened, never
  bound, and never re-armed — and re-arming is what decides whether a stream keeps going
  past the first burst.

  The sender is the one from `PiFi.AirPlay.AudioPacketTest`, written from the layout
  rather than from the code that reads it.
  """

  use ExUnit.Case, async: true

  alias PiFi.AirPlay.AudioSocket

  @payload_type 96

  defp key, do: :crypto.strong_rand_bytes(32)

  defp sent(audio, options) do
    key = Keyword.fetch!(options, :key)
    sequence = Keyword.get(options, :sequence, 0)
    timestamp = Keyword.get(options, :timestamp, 1_000)
    ssrc = 0xDEADBEEF
    short = :crypto.strong_rand_bytes(8)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :chacha20_poly1305,
        key,
        <<0::32, short::binary>>,
        audio,
        <<timestamp::32, ssrc::32>>,
        true
      )

    <<2::2, 0::1, 0::1, 0::4, 0::1, @payload_type::7, sequence::16, timestamp::32, ssrc::32,
      ciphertext::binary, tag::binary, short::binary>>
  end

  defp listening(options \\ []) do
    key = Keyword.get_lazy(options, :key, &key/0)

    {:ok, receiver} = start_supervised({AudioSocket, Keyword.merge([key: key], options)})
    {:ok, port} = AudioSocket.port(receiver)
    {:ok, sender} = :gen_udp.open(0, [:binary])

    on_exit(fn -> :gen_udp.close(sender) end)

    %{
      receiver: receiver,
      port: port,
      key: key,
      send: &:gen_udp.send(sender, {127, 0, 0, 1}, port, &1)
    }
  end

  # The datagrams have to have arrived before taking means anything, and arriving is
  # something another process does.
  defp arrived(receiver, count) do
    eventually(fn -> AudioSocket.statistics(receiver).received >= count end)
  end

  defp taken(receiver, count) do
    Enum.map(1..count, fn _one -> AudioSocket.take(receiver) end)
  end

  describe "a session that is sending" do
    test "the audio comes back" do
      %{receiver: receiver, key: key, send: send} = listening()

      send.(sent("a frame", key: key, sequence: 0))
      assert arrived(receiver, 1)

      assert {:ok, %{payload: "a frame", sequence: 0}} = AudioSocket.take(receiver)
    end

    test "the timestamp comes with it" do
      %{receiver: receiver, key: key, send: send} = listening()

      send.(sent("audio", key: key, sequence: 0, timestamp: 987_654))
      assert arrived(receiver, 1)

      assert {:ok, %{timestamp: 987_654}} = AudioSocket.take(receiver)
    end

    test "nothing to take says so rather than waiting" do
      %{receiver: receiver} = listening()

      assert AudioSocket.take(receiver) == :empty
    end

    # **The port is the whole reason this exists**: it is what the answer to `SETUP`
    # names, so a sender has somewhere to send.
    test "it says which port it bound" do
      %{port: port} = listening()

      assert is_integer(port) and port > 0
    end
  end

  describe "packets that arrive out of order" do
    # **This is the whole reason a jitter buffer is here**, and the reason nothing is
    # pushed. An earlier version drained after every datagram, which handed on whichever
    # packet arrived first and left the two that overtook it too late to use.
    test "are given back in order" do
      %{receiver: receiver, key: key, send: send} = listening()

      for sequence <- [2, 0, 1],
          do: send.(sent("frame #{sequence}", key: key, sequence: sequence))

      assert arrived(receiver, 3)

      assert [{:ok, %{sequence: 0}}, {:ok, %{sequence: 1}}, {:ok, %{sequence: 2}}] =
               taken(receiver, 3)
    end

    # **Reading starts at the oldest packet held and not at zero.** A sender picks where
    # its sequence numbers begin, so a receiver that waited for 0 would wait for a packet
    # that was never sent.
    test "the first packet to arrive starts the stream, whatever its number" do
      %{receiver: receiver, key: key, send: send} = listening()

      send.(sent("first of this stream", key: key, sequence: 9_000))
      assert arrived(receiver, 1)

      assert {:ok, %{sequence: 9_000}} = AudioSocket.take(receiver)
    end

    # Once reading has started there is a packet that is next, and one that has not come
    # yet holds up everything behind it — that is the waiting a jitter buffer does.
    test "a packet still missing holds up the ones behind it" do
      %{receiver: receiver, key: key, send: send} = listening()

      send.(sent("first", key: key, sequence: 0))
      assert arrived(receiver, 1)
      assert {:ok, %{sequence: 0}} = AudioSocket.take(receiver)

      send.(sent("third", key: key, sequence: 2))
      assert arrived(receiver, 2)

      # Sequence 1 may still be on its way, so 2 is not due yet.
      assert AudioSocket.take(receiver) == :empty

      send.(sent("second", key: key, sequence: 1))
      assert arrived(receiver, 3)

      assert {:ok, %{sequence: 1}} = AudioSocket.take(receiver)
      assert {:ok, %{sequence: 2}} = AudioSocket.take(receiver)
    end

    # A packet that never comes must not stop the stream for ever. The buffer gives up
    # once it holds something far enough past the gap, and says so rather than hiding it.
    test "a packet that never comes becomes a gap" do
      %{receiver: receiver, key: key, send: send} = listening(depth: 4)

      send.(sent("first", key: key, sequence: 0))
      for sequence <- 2..8, do: send.(sent("later", key: key, sequence: sequence))
      assert arrived(receiver, 8)

      assert {:ok, %{sequence: 0}} = AudioSocket.take(receiver)
      assert {:gap, 1} = AudioSocket.take(receiver)
      assert {:ok, %{sequence: 2}} = AudioSocket.take(receiver)
    end

    test "a duplicate is not played twice" do
      %{receiver: receiver, key: key, send: send} = listening()

      send.(sent("once", key: key, sequence: 0))
      send.(sent("again", key: key, sequence: 0))
      assert arrived(receiver, 2)

      assert {:ok, %{sequence: 0}} = AudioSocket.take(receiver)
      assert AudioSocket.take(receiver) == :empty
    end
  end

  describe "a datagram that will not open" do
    # **Anything on the network can send to this port.** None of it may take the session
    # down, and none of it may be played.
    test "is dropped rather than played" do
      %{receiver: receiver, send: send} = listening()

      send.(:crypto.strong_rand_bytes(128))
      send.(<<0, 1, 2, 3>>)
      send.(<<>>)
      assert arrived(receiver, 3)

      assert AudioSocket.take(receiver) == :empty
    end

    test "leaves the socket taking real audio afterwards" do
      %{receiver: receiver, key: key, send: send} = listening()

      send.(:crypto.strong_rand_bytes(128))
      send.(sent("real audio", key: key, sequence: 0))
      assert arrived(receiver, 2)

      assert {:ok, %{payload: "real audio"}} = AudioSocket.take(receiver)
    end

    test "one sealed with another key is refused" do
      %{receiver: receiver, send: send} = listening()

      send.(sent("audio", key: key(), sequence: 0))
      assert arrived(receiver, 1)

      assert AudioSocket.take(receiver) == :empty
    end

    # A bad stream would write hundreds of log lines a second, so the count is the only
    # place this shows up.
    test "is counted" do
      %{receiver: receiver, key: key, send: send} = listening()

      send.(sent("good", key: key, sequence: 0))
      send.(:crypto.strong_rand_bytes(128))
      send.(<<0, 1, 2, 3>>)

      assert eventually(fn -> AudioSocket.statistics(receiver).refused == 2 end)

      statistics = AudioSocket.statistics(receiver)

      assert statistics.received == 3
      assert statistics.held == 1
    end
  end

  describe "a sender going faster than this reads" do
    # **The socket delivers a fixed number of datagrams and then goes quiet until it is
    # asked again.** Without re-arming, a stream stops dead after the first burst — which
    # is a fifth of a second of real audio, so nothing shorter than this would notice.
    # **In waves, each one waited for.** Firing five hundred datagrams at a loopback
    # socket as fast as a loop can send them drops some of them, which is UDP behaving
    # exactly as UDP does and not something this can fix — it made this test fail about
    # one run in fifty. Waiting for each wave tests the thing that matters without
    # depending on the kernel absorbing a burst.
    test "keeps taking packets well past one burst" do
      %{receiver: receiver, key: key, send: send} = listening(capacity: 2_048)

      waves = 5
      each = 50

      for wave <- 0..(waves - 1) do
        for step <- 0..(each - 1) do
          send.(sent("frame", key: key, sequence: wave * each + step))
        end

        assert arrived(receiver, (wave + 1) * each)
      end

      # 250 datagrams through a socket that delivers 64 at a time means it asked for more
      # at least three times.
      assert AudioSocket.statistics(receiver).received == waves * each

      assert taken(receiver, waves * each)
             |> Enum.map(fn {:ok, packet} -> packet.sequence end) ==
               Enum.to_list(0..(waves * each - 1))
    end
  end

  describe "a session that ends" do
    # **The socket itself is asked, not the port number.** Binding the number again
    # looked like the honest proof and is a race: the operating system is free to hand
    # that ephemeral number to any other socket in the meantime, and this suite opens a
    # great many. `Port.info/1` answers `nil` for a socket that is closed and nothing
    # else can make it lie.
    test "gives the socket back" do
      %{receiver: receiver} = listening()
      socket = :sys.get_state(receiver).socket

      assert Port.info(socket)

      stop_supervised!(AudioSocket)

      refute Process.alive?(receiver)
      refute Port.info(socket)
    end
  end

  defp eventually(check, attempts \\ 200)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end
end
