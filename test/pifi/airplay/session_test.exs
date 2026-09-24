defmodule PiFi.AirPlay.SessionTest do
  @moduledoc """
  The sockets one connection opens, and whether they are really there.

  **Every port this answers with gets connected to.** A sender whose connection is
  refused abandons the session, so a test that only read the numbers out of the reply
  would pass for a session that named three ports and held none of them — which is the
  one way this can fail that looks exactly like success.
  """

  use ExUnit.Case, async: true

  alias PiFi.AirPlay.AudioSocket
  alias PiFi.AirPlay.BinaryPlist
  alias PiFi.AirPlay.Session

  defp key, do: :crypto.strong_rand_bytes(32)

  defp first(options \\ []) do
    BinaryPlist.encode(%{
      "name" => Keyword.get(options, :name, "A telephone"),
      "timingProtocol" => Keyword.get(options, :timing, "PTP")
    })
  end

  defp second(options \\ []) do
    BinaryPlist.encode(%{
      "streams" => [
        %{
          "type" => Keyword.get(options, :type, 96),
          "shk" => {:data, Keyword.get_lazy(options, :key, &key/0)},
          "sr" => 44_100,
          "spf" => 352
        }
      ]
    })
  end

  defp opened(session), do: on_exit(fn -> Session.close(session) end)

  describe "the first SETUP" do
    test "names a port that something is listening on" do
      assert {:ok, reply, session} = Session.setup(Session.new(), first())
      opened(session)

      assert {:ok, connected} =
               :gen_tcp.connect({127, 0, 0, 1}, reply["eventPort"], [:binary], 1_000)

      :gen_tcp.close(connected)
    end

    test "remembers what the sender called itself and how it keeps time" do
      assert {:ok, _reply, session} =
               Session.setup(Session.new(), first(name: "James's iPhone", timing: "NTP"))

      opened(session)

      assert session.name == "James's iPhone"
      assert session.timing == :ntp
    end

    # A sender sends `SETUP` twice and the first message can arrive twice if it retries.
    # Opening a second listener would leak the first.
    test "asked twice, it opens one port and keeps it" do
      assert {:ok, one, session} = Session.setup(Session.new(), first())
      assert {:ok, two, session} = Session.setup(session, first())
      opened(session)

      assert one["eventPort"] == two["eventPort"]
    end
  end

  describe "the second SETUP" do
    test "names a port the audio can be sent to" do
      assert {:ok, _reply, session} = Session.setup(Session.new(), first())
      assert {:ok, reply, session} = Session.setup(session, second())
      opened(session)

      assert [%{"dataPort" => data, "controlPort" => control}] = reply["streams"]

      # Sending to a port nothing holds gives no error to the sender, so the proof is
      # that the socket is the one the session reports.
      assert {:ok, ^data} = AudioSocket.port(session.audio)
      assert {:ok, ^control} = :inet.port(session.control)
    end

    test "the audio socket takes the key the sender gave" do
      shk = key()

      assert {:ok, _reply, session} = Session.setup(Session.new(), first())
      assert {:ok, reply, session} = Session.setup(session, second(key: shk))
      opened(session)

      [%{"dataPort" => data}] = reply["streams"]

      assert AudioSocket.statistics(session.audio).received == 0

      {:ok, sender} = :gen_udp.open(0, [:binary])
      :gen_udp.send(sender, {127, 0, 0, 1}, data, sealed("audio", shk))
      :gen_tcp.close(sender)

      assert eventually(fn -> match?({:ok, %{payload: "audio"}}, Session.take(session)) end)
    end

    test "the data and control ports are not the same one" do
      assert {:ok, _reply, session} = Session.setup(Session.new(), first())
      assert {:ok, reply, session} = Session.setup(session, second())
      opened(session)

      assert [%{"dataPort" => data, "controlPort" => control}] = reply["streams"]
      assert data != control
    end

    # **A remote control connection carries no audio**, so there is no audio socket to
    # make. It still has to be given a port, because a sender connects to what it is told.
    test "a remote control stream opens no audio socket" do
      body = BinaryPlist.encode(%{"streams" => [%{"type" => 130}]})

      assert {:ok, _reply, session} = Session.setup(Session.new(), first(timing: "None"))
      assert {:ok, reply, session} = Session.setup(session, body)
      opened(session)

      assert session.audio == nil
      assert [%{"dataPort" => data}] = reply["streams"]
      assert is_integer(data) and data > 0
    end

    test "a stream it cannot read opens nothing and says so" do
      body = BinaryPlist.encode(%{"streams" => [%{"type" => 110}]})

      assert {:ok, _reply, session} = Session.setup(Session.new(), first())
      assert {:error, {:unsupported_stream, 110}} = Session.setup(session, body)
      opened(session)
    end

    test "a session with no audio has nothing to take" do
      assert {:ok, _reply, session} = Session.setup(Session.new(), first())
      opened(session)

      assert Session.take(session) == :empty
    end
  end

  describe "closing" do
    # **Each socket is asked, not its port number.** Binding a number again is a race
    # against every other socket in the suite, because the operating system may hand that
    # ephemeral number to one of them in between. `Port.info/1` answers `nil` for a
    # socket that is closed.
    test "gives every socket back" do
      assert {:ok, _event_reply, session} = Session.setup(Session.new(), first())
      assert {:ok, _reply, session} = Session.setup(session, second())

      audio = session.audio
      sockets = [session.event, session.control, :sys.get_state(audio).socket]

      for socket <- sockets, do: assert(Port.info(socket))

      assert Session.close(session) == Session.new()

      refute Process.alive?(audio)
      for socket <- sockets, do: refute(Port.info(socket))
    end

    # **Closing the listener is not enough.** A sender has already connected to the event
    # port by this point, and that accepted socket has an owner of its own — one that
    # goes on holding it after the listener is shut. Nothing rebinding the port would
    # notice, so this asks the sender's end whether it was dropped.
    test "drops the event connection a sender had open" do
      assert {:ok, reply, session} = Session.setup(Session.new(), first())

      assert {:ok, connected} =
               :gen_tcp.connect(
                 {127, 0, 0, 1},
                 reply["eventPort"],
                 [:binary, active: true],
                 1_000
               )

      Session.close(session)

      assert_receive {:tcp_closed, ^connected}, 1_000
    end

    # A sender that crashed sends no `TEARDOWN`, and a connection that never got as far
    # as `SETUP` still ends.
    test "a session that opened nothing closes without complaint" do
      assert Session.close(Session.new()) == Session.new()
    end

    test "closing twice is not an error" do
      assert {:ok, _reply, session} = Session.setup(Session.new(), first())

      closed = Session.close(session)

      assert Session.close(closed) == Session.new()
    end
  end

  defp sealed(audio, key) do
    short = :crypto.strong_rand_bytes(8)
    timestamp = 1_000
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

    <<2::2, 0::1, 0::1, 0::4, 0::1, 96::7, 0::16, timestamp::32, ssrc::32, ciphertext::binary,
      tag::binary, short::binary>>
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
