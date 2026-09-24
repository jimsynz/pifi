defmodule PiFi.AirPlay.SetupTest do
  @moduledoc """
  The two `SETUP` messages, read and answered.

  **The shapes here come from Shairport Sync's `rtsp.c`**, which is MIT and is a
  receiver that real telephones talk to every day. They are not from a telephone this
  project has observed, so the first one that connects is what settles them — the
  reading below is written so that a wrong guess shows up as a failing expectation
  rather than as audio that never arrives.
  """

  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.Setup

  alias PiFi.AirPlay.BinaryPlist
  alias PiFi.AirPlay.Setup

  defp body(plist), do: BinaryPlist.encode(plist)

  defp key, do: :crypto.strong_rand_bytes(32)

  describe "telling the two messages apart" do
    # **There is no field that names the phase.** A sender sends `SETUP` twice on one
    # connection and the only difference is whether a `streams` array came with it, so
    # reading that wrong means answering the wrong message entirely.
    test "no streams array is the first message" do
      assert {:ok, {:session, _details}} = Setup.read(body(%{"timingProtocol" => "PTP"}))
    end

    test "a streams array is the second" do
      assert {:ok, {:streams, _streams}} =
               Setup.read(body(%{"streams" => [%{"type" => 96, "shk" => {:data, key()}}]}))
    end

    # A sender that sends neither is one this cannot answer, and saying so beats reading
    # a session out of an empty dictionary.
    test "a streams array with nothing in it is refused" do
      assert {:error, :no_streams} = Setup.read(body(%{"streams" => []}))
    end

    test "a body that is not a plist at all is refused" do
      assert {:error, _reason} = Setup.read(<<"not a plist">>)
    end
  end

  describe "the first message" do
    test "reads the timing protocol a sender asked for" do
      for {named, read} <- [{"PTP", :ptp}, {"NTP", :ntp}, {"None", :none}] do
        assert {:ok, {:session, session}} = Setup.read(body(%{"timingProtocol" => named}))
        assert session.timing == read
      end
    end

    # A sender that names no protocol wants no timing, which is what a remote control
    # connection is. It must not be read as PTP, because that is the one that makes this
    # receiver expect a clock.
    test "a sender that names no protocol gets none rather than a guess" do
      assert {:ok, {:session, session}} = Setup.read(body(%{"name" => "A telephone"}))
      assert session.timing == :none
    end

    test "reads the name a sender calls itself" do
      assert {:ok, {:session, session}} = Setup.read(body(%{"name" => "James's iPhone"}))
      assert session.name == "James's iPhone"
    end

    test "a sender that gives no name is not a failure" do
      assert {:ok, {:session, session}} = Setup.read(body(%{"timingProtocol" => "PTP"}))
      assert session.name == nil
    end

    # **This connection carries no audio.** It is a telephone asking to drive something
    # else that is playing, and treating it as a stream would open sockets for audio
    # that is never sent.
    test "notices a connection that is remote control only" do
      assert {:ok, {:session, session}} =
               Setup.read(body(%{"timingProtocol" => "None", "isRemoteControlOnly" => true}))

      assert session.remote_control_only?
    end

    test "an ordinary session is not remote control only" do
      assert {:ok, {:session, session}} = Setup.read(body(%{"timingProtocol" => "PTP"}))
      refute session.remote_control_only?
    end
  end

  describe "the second message" do
    test "reads a realtime audio stream" do
      shk = key()

      assert {:ok, {:streams, [stream]}} =
               Setup.read(
                 body(%{
                   "streams" => [
                     %{
                       "type" => 96,
                       "shk" => {:data, shk},
                       "ct" => 2,
                       "sr" => 44_100,
                       "spf" => 352
                     }
                   ]
                 })
               )

      assert stream.kind == :realtime
      assert stream.key == shk
      assert stream.compression == 2
      assert stream.sample_rate == 44_100
      assert stream.frames_per_packet == 352
    end

    test "reads a buffered audio stream" do
      assert {:ok, {:streams, [stream]}} =
               Setup.read(body(%{"streams" => [%{"type" => 103, "shk" => {:data, key()}}]}))

      assert stream.kind == :buffered
    end

    test "reads a remote control stream, which carries no key" do
      assert {:ok, {:streams, [stream]}} =
               Setup.read(body(%{"streams" => [%{"type" => 130}]}))

      assert stream.kind == :remote_control
      assert stream.key == nil
    end

    test "reads more than one stream in the order they arrived" do
      assert {:ok, {:streams, streams}} =
               Setup.read(
                 body(%{
                   "streams" => [
                     %{"type" => 96, "shk" => {:data, key()}},
                     %{"type" => 130}
                   ]
                 })
               )

      assert Enum.map(streams, & &1.kind) == [:realtime, :remote_control]
    end

    # The fields a sender names for the audio are reported rather than obeyed: the
    # evidence on the issue is that it sends ALAC regardless. Reporting them is what
    # lets the first real telephone settle that.
    test "a stream that names nothing about its audio still reads" do
      assert {:ok, {:streams, [stream]}} =
               Setup.read(body(%{"streams" => [%{"type" => 96, "shk" => {:data, key()}}]}))

      assert stream.compression == nil
      assert stream.sample_rate == nil
      assert stream.frames_per_packet == nil
    end

    test "a stream of a kind this does not serve is refused by number" do
      assert {:error, {:unsupported_stream, 110}} =
               Setup.read(body(%{"streams" => [%{"type" => 110}]}))
    end

    test "a stream with no type at all is refused" do
      assert {:error, :stream_has_no_type} = Setup.read(body(%{"streams" => [%{"sr" => 44_100}]}))
    end

    # **One bad stream refuses the message.** Answering for the ones that read and
    # quietly dropping the rest would have a sender waiting on a port that was never
    # named.
    test "one stream it cannot read refuses the whole message" do
      assert {:error, {:unsupported_stream, 110}} =
               Setup.read(
                 body(%{
                   "streams" => [%{"type" => 96, "shk" => {:data, key()}}, %{"type" => 110}]
                 })
               )
    end
  end

  describe "the session key" do
    # **It becomes the ChaCha20-Poly1305 key for every audio packet.** A key of another
    # length is not a key, and taking it would read past its end on each packet rather
    # than failing once here.
    test "has to be thirty-two bytes" do
      for length <- [0, 16, 31, 33, 64] do
        assert {:error, {:bad_session_key, ^length}} =
                 Setup.read(
                   body(%{
                     "streams" => [%{"type" => 96, "shk" => {:data, :binary.copy(<<0>>, length)}}]
                   })
                 )
      end
    end

    test "thirty-two bytes is taken" do
      shk = key()

      assert {:ok, {:streams, [%{key: ^shk}]}} =
               Setup.read(body(%{"streams" => [%{"type" => 96, "shk" => {:data, shk}}]}))
    end
  end

  describe "answering the first message" do
    test "names the port the event channel listens on" do
      assert %{"eventPort" => 7000} = Setup.session_reply(7000)
    end

    # The timing of a PTP session happens on the two well-known ports of IEEE 1588
    # rather than on one this receiver picks, so there is no number to give. Every
    # receiver sends zero, and a sender that got something else would try to use it.
    test "the timing port is zero, because PTP does not use one of ours" do
      assert %{"timingPort" => 0} = Setup.session_reply(7000)
    end
  end

  describe "answering the second message" do
    test "a realtime stream is told where to send audio and control" do
      streams = [
        %{kind: :realtime, key: nil, compression: 2, sample_rate: 44_100, frames_per_packet: 352}
      ]

      assert %{"streams" => [reply]} = Setup.streams_reply(streams, data: 6000, control: 6001)

      assert reply == %{"type" => 96, "dataPort" => 6000, "controlPort" => 6001}
    end

    # A buffered sender asks how much this will hold, and fills it before it starts. A
    # reply with no size would have it send as fast as the socket takes.
    test "a buffered stream is told how much this will hold" do
      streams = [
        %{kind: :buffered, key: nil, compression: nil, sample_rate: nil, frames_per_packet: nil}
      ]

      assert %{"streams" => [reply]} = Setup.streams_reply(streams, data: 6000, control: 6001)

      assert reply["type"] == 103
      assert reply["audioBufferSize"] > 0
    end

    test "the size this will hold can be said" do
      streams = [
        %{kind: :buffered, key: nil, compression: nil, sample_rate: nil, frames_per_packet: nil}
      ]

      assert %{"streams" => [reply]} =
               Setup.streams_reply(streams, data: 6000, control: 6001, buffer_size: 1024)

      assert reply["audioBufferSize"] == 1024
    end

    # It carries no audio, so it is given no control port.
    test "a remote control stream is told one port and no more" do
      streams = [
        %{
          kind: :remote_control,
          key: nil,
          compression: nil,
          sample_rate: nil,
          frames_per_packet: nil
        }
      ]

      assert %{"streams" => [reply]} = Setup.streams_reply(streams, data: 6000, control: 6001)

      assert reply == %{"type" => 130, "dataPort" => 6000}
    end

    test "the answer survives a round trip through a plist" do
      streams = [
        %{kind: :realtime, key: nil, compression: 2, sample_rate: 44_100, frames_per_packet: 352}
      ]

      encoded = streams |> Setup.streams_reply(data: 6000, control: 6001) |> BinaryPlist.encode()

      assert {:ok, %{"streams" => [%{"dataPort" => 6000}]}} = BinaryPlist.decode(encoded)
    end
  end
end
