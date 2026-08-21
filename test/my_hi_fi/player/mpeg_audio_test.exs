defmodule MyHiFi.Player.MpegAudioTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Player.MpegAudio

  describe "handle_buffer/4" do
    test "removes the timestamp of a buffer" do
      # `membrane_mp3_mad_plugin` holds a fault. A live stream starts at any point,
      # so the first frame that the decoder sees is almost always a part of a
      # frame. The decoder calls that recoverable, steps over it, and then asks for
      # the time of the next frame from a stream format that is not there yet. Only
      # a buffer with a timestamp starts that step.
      buffer = %Membrane.Buffer{payload: "some mp3", pts: 1_000_000, dts: 900_000}

      assert {[buffer: {:output, out}], _state} =
               MpegAudio.handle_buffer(:input, buffer, nil, %{})

      assert out.pts == nil
      assert out.dts == nil
      assert out.payload == "some mp3"
    end

    test "a buffer with no timestamp passes through" do
      buffer = %Membrane.Buffer{payload: "already plain"}

      assert {[buffer: {:output, out}], _state} =
               MpegAudio.handle_buffer(:input, buffer, nil, %{})

      assert out.payload == "already plain"
      assert out.pts == nil
    end
  end

  describe "handle_stream_format/4" do
    test "names a remote stream, which MAD takes" do
      assert {[stream_format: {:output, %Membrane.RemoteStream{}}], _state} =
               MpegAudio.handle_stream_format(
                 :input,
                 %Membrane.RemoteStream{content_format: %Membrane.MPEG.TS.StreamFormat{}},
                 nil,
                 %{}
               )
    end
  end
end
