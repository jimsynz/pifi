defmodule MyHiFi.Player.PackedAudioTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Player.PackedAudio

  # The size of an ID3v2 tag holds seven bits in each of four bytes.
  defp syncsafe(size) do
    <<0::1, Bitwise.bsr(size, 21)::7, 0::1, Bitwise.bsr(size, 14)::7, 0::1,
      Bitwise.bsr(size, 7)::7, 0::1, size::7>>
  end

  defp tag(body, flags \\ 0) do
    "ID3" <> <<4, 0, flags>> <> syncsafe(byte_size(body)) <> body
  end

  defp feed(chunks) do
    {_actions, state} = PackedAudio.handle_init(nil, nil)

    Enum.reduce(chunks, {<<>>, state}, fn chunk, {audio, state} ->
      {actions, state} =
        PackedAudio.handle_buffer(:input, %Membrane.Buffer{payload: chunk}, nil, state)

      more =
        for {:buffer, {:output, %Membrane.Buffer{payload: payload}}} <- actions,
            into: <<>>,
            do: payload

      {audio <> more, state}
    end)
    |> elem(0)
  end

  describe "a segment that starts with a tag" do
    test "gives the audio and no tag" do
      assert feed([tag("timestamp here") <> "audio bytes"]) == "audio bytes"
    end

    test "removes a tag that holds a footer as well" do
      # Bit 4 of the flags says that ten more bytes sit at the end of the tag.
      body = "the body of it"
      footer = String.duplicate("f", 10)

      assert feed([tag(body, 0x10) <> footer <> "audio"]) == "audio"
    end

    test "removes two tags that follow one another in one segment" do
      # The stations of one New Zealand network send a timestamp tag and then a
      # tag that holds the title of the track.
      timestamp = tag("com.apple.streaming.transportStreamTimestamp")
      title = tag("TIT2 Ed Sheeran - Bad Habits")

      assert feed([timestamp <> title <> "audio"]) == "audio"
    end

    test "removes three tags that follow one another" do
      assert feed([tag("one") <> tag("two") <> tag("three") <> "audio"]) == "audio"
    end

    test "removes a second tag that starts in the next buffer" do
      whole = tag("first") <> tag("second") <> "audio"
      <<head::binary-size(20), rest::binary>> = whole

      assert feed([head, rest]) == "audio"
    end

    test "removes a tag of each segment" do
      one = tag("first") <> "audio one"
      two = tag("second") <> "audio two"

      assert feed([one, two]) == "audio oneaudio two"
    end
  end

  describe "a tag that arrives in pieces" do
    test "one byte at a time still gives the audio" do
      whole = tag("a timestamp") <> "the audio"
      chunks = whole |> :binary.bin_to_list() |> Enum.map(&<<&1>>)

      assert feed(chunks) == "the audio"
    end

    test "a chunk that ends inside the identifier" do
      whole = tag("a timestamp") <> "the audio"
      <<first::binary-size(2), rest::binary>> = whole

      assert feed([first, rest]) == "the audio"
    end

    test "a chunk that ends inside the header" do
      whole = tag("a timestamp") <> "the audio"
      <<first::binary-size(7), rest::binary>> = whole

      assert feed([first, rest]) == "the audio"
    end

    test "a chunk that ends inside the body of the tag" do
      whole = tag(String.duplicate("x", 40)) <> "the audio"
      <<first::binary-size(20), rest::binary>> = whole

      assert feed([first, rest]) == "the audio"
    end
  end

  describe "audio with no tag" do
    test "passes through" do
      assert feed(["plain audio bytes"]) == "plain audio bytes"
    end

    test "the same three bytes inside the audio are audio" do
      # A tag arrives at the start of a segment only. `ID3` further in is sound.
      assert feed(["audio ID3 more audio"]) == "audio ID3 more audio"
    end

    test "a short buffer that cannot hold a tag passes through" do
      assert feed(["abc"]) == "abc"
    end
  end

  describe "the stream format" do
    test "names a remote stream with no content format, which the decoder takes" do
      {_actions, state} = PackedAudio.handle_init(nil, nil)

      assert {[stream_format: {:output, %Membrane.RemoteStream{content_format: nil}}], _state} =
               PackedAudio.handle_stream_format(
                 :input,
                 %Membrane.HLS.Format.PackedAudio{},
                 nil,
                 state
               )
    end
  end
end
