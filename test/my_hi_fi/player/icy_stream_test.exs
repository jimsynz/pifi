defmodule MyHiFi.Player.IcyStreamTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Player.IcyStream

  # A block holds the length in units of 16 bytes, so the text needs padding.
  defp block(text) do
    units = ceil(byte_size(text) / 16)
    padding = units * 16 - byte_size(text)

    <<units>> <> text <> String.duplicate(<<0>>, padding)
  end

  defp title_block(title), do: block("StreamTitle='#{title}';")

  defp empty_block, do: <<0>>

  defp audio(count), do: String.duplicate("a", count)

  describe "a station that sends no metadata" do
    test "gives every byte as audio" do
      icy = IcyStream.new(nil)

      assert {"hello", [], icy} = IcyStream.split(icy, "hello")
      assert {" world", [], _icy} = IcyStream.split(icy, " world")
    end

    test "keeps the bytes of a block, because there is no block" do
      icy = IcyStream.new(nil)
      data = audio(8) <> title_block("Not a title")

      assert {^data, [], _icy} = IcyStream.split(icy, data)
    end
  end

  describe "one chunk that holds a whole block" do
    test "takes the block out and gives the title" do
      icy = IcyStream.new(16)
      data = audio(16) <> title_block("Coldplay - Hymn") <> audio(4)

      assert {audio, ["Coldplay - Hymn"], _icy} = IcyStream.split(icy, data)
      assert audio == audio(20)
    end

    test "an empty block gives no title" do
      icy = IcyStream.new(16)
      data = audio(16) <> empty_block() <> audio(16)

      assert {audio, [], _icy} = IcyStream.split(icy, data)
      assert audio == audio(32)
    end

    test "reads each block of a long chunk" do
      icy = IcyStream.new(4)

      data =
        audio(4) <>
          title_block("First") <>
          audio(4) <> empty_block() <> audio(4) <> title_block("Second") <> audio(4)

      assert {audio, ["First", "Second"], _icy} = IcyStream.split(icy, data)
      assert audio == audio(16)
    end
  end

  describe "a block that arrives in pieces" do
    test "one byte at a time still gives the title and the audio" do
      whole = audio(16) <> title_block("Slow arrival") <> audio(16)

      {audio, titles, _icy} =
        whole
        |> :binary.bin_to_list()
        |> Enum.reduce({<<>>, [], IcyStream.new(16)}, fn byte, {audio, titles, icy} ->
          {more, new_titles, icy} = IcyStream.split(icy, <<byte>>)
          {audio <> more, titles ++ new_titles, icy}
        end)

      assert audio == audio(32)
      assert titles == ["Slow arrival"]
    end

    test "a chunk that ends on the length byte" do
      icy = IcyStream.new(8)
      whole = audio(8) <> title_block("Split here") <> audio(8)
      <<first::binary-size(9), rest::binary>> = whole

      {audio_one, [], icy} = IcyStream.split(icy, first)
      {audio_two, titles, _icy} = IcyStream.split(icy, rest)

      assert audio_one <> audio_two == audio(16)
      assert titles == ["Split here"]
    end

    test "a chunk boundary inside the audio" do
      icy = IcyStream.new(100)
      whole = audio(100) <> title_block("Later") <> audio(50)
      <<first::binary-size(40), rest::binary>> = whole

      {audio_one, [], icy} = IcyStream.split(icy, first)
      {audio_two, titles, _icy} = IcyStream.split(icy, rest)

      assert byte_size(audio_one <> audio_two) == 150
      assert titles == ["Later"]
    end
  end

  describe "the same title twice" do
    test "gives the title once only" do
      icy = IcyStream.new(4)

      data =
        audio(4) <>
          title_block("Once") <> audio(4) <> title_block("Once") <> audio(4)

      assert {_audio, ["Once"], icy} = IcyStream.split(icy, data)

      assert {_audio, [], _icy} =
               IcyStream.split(icy, title_block("Once") <> audio(4))
    end

    test "gives the new title when the track changes" do
      icy = IcyStream.new(4)

      assert {_audio, ["First"], icy} =
               IcyStream.split(icy, audio(4) <> title_block("First") <> audio(4))

      assert {_audio, ["Second"], _icy} =
               IcyStream.split(icy, title_block("Second") <> audio(4))
    end
  end

  describe "what a block holds" do
    test "reads a block that names more than the title" do
      icy = IcyStream.new(4)
      text = "StreamTitle='A Song';StreamUrl='http://example.test/';"

      assert {_audio, ["A Song"], _icy} =
               IcyStream.split(icy, audio(4) <> block(text))
    end

    test "gives no title for a block with an empty title" do
      icy = IcyStream.new(4)

      assert {_audio, [], _icy} =
               IcyStream.split(icy, audio(4) <> title_block(""))
    end

    test "gives no title for a block that names nothing" do
      icy = IcyStream.new(4)

      assert {_audio, [], _icy} =
               IcyStream.split(icy, audio(4) <> block("StreamUrl='http://example.test/';"))
    end

    test "reads a title that holds Latin-1 bytes" do
      icy = IcyStream.new(4)
      # 0xE9 is `é` in Latin-1, and it is not a UTF-8 sequence on its own.
      text = <<"StreamTitle='Caf", 0xE9, "';">>

      assert {_audio, ["Café"], _icy} = IcyStream.split(icy, audio(4) <> block(text))
    end

    test "reads a title that holds UTF-8" do
      icy = IcyStream.new(4)

      assert {_audio, ["Café"], _icy} =
               IcyStream.split(icy, audio(4) <> title_block("Café"))
    end
  end

  describe "a real block from a station" do
    test "reads what a Shoutcast server sent" do
      icy = IcyStream.new(16_384)

      # Captured from a station on 2026-08-21. The length byte is 4, so the block
      # holds 64 bytes, and the server padded the text with nulls.
      raw =
        <<83, 116, 114, 101, 97, 109, 84, 105, 116, 108, 101, 61, 39, 80, 108, 97, 121, 105, 110,
          103, 32, 78, 111, 119, 32, 32, 67, 111, 108, 100, 112, 108, 97, 121, 32, 45, 32, 72,
          121, 109, 110, 32, 70, 111, 114, 32, 84, 104, 101, 32, 87, 101, 101, 107, 101, 110, 100,
          39, 59, 0, 0, 0, 0, 0>>

      data = audio(16_384) <> <<4>> <> raw

      assert {audio, ["Playing Now  Coldplay - Hymn For The Weekend"], _icy} =
               IcyStream.split(icy, data)

      assert byte_size(audio) == 16_384
    end
  end
end
