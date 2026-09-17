defmodule PiFi.Player.OggTest do
  use ExUnit.Case, async: true

  alias PiFi.Player.Ogg

  setup do
    Application.put_env(:pifi, Ogg, plug: {Req.Test, Ogg}, retry: false)
    on_exit(fn -> Application.delete_env(:pifi, Ogg) end)
    :ok
  end

  defp stub(body) do
    Req.Test.stub(Ogg, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
  end

  # An Ogg page, and then the identification header of the codec. The real header
  # sits a few bytes into the page.
  defp page(identification) do
    "OggS" <> <<0, 2, 0::64, 0::32, 0::32, 0::32, 1, 30>> <> identification
  end

  describe "codec/1" do
    test "names Vorbis" do
      stub(page(<<0x01, "vorbis">>))

      assert {:ok, :vorbis} = Ogg.codec("http://station.test/stream")
    end

    test "names FLAC" do
      stub(page(<<0x7F, "FLAC", 1, 0>>))

      assert {:ok, :flac} = Ogg.codec("http://station.test/stream")
    end

    test "names Opus" do
      stub(page("OpusHead"))

      assert {:ok, :opus} = Ogg.codec("http://station.test/stream")
    end

    test "names Speex" do
      stub(page("Speex   "))

      assert {:ok, :speex} = Ogg.codec("http://station.test/stream")
    end

    test "FLAC wins over the word vorbis, which a comment of FLAC can hold" do
      # A FLAC stream carries a vendor string, and that string names libVorbis on
      # some servers. The identification header decides, and FLAC comes first.
      stub(page(<<0x7F, "FLAC", 1, 0>>) <> <<0x01, "vorbis">>)

      assert {:ok, :flac} = Ogg.codec("http://station.test/stream")
    end
  end

  describe "a stream that names no codec" do
    test "an answer with no identification header gives an error" do
      stub("this is not an Ogg stream at all")

      assert {:error, :unknown_ogg_codec} = Ogg.codec("http://station.test/stream")
    end

    test "an empty answer gives an error" do
      stub("")

      assert {:error, :no_bytes} = Ogg.codec("http://station.test/stream")
    end

    test "an answer that is not 200 gives an error" do
      Req.Test.stub(Ogg, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, {:status, 404}} = Ogg.codec("http://station.test/gone")
    end

    test "a network fault gives an error" do
      Req.Test.stub(Ogg, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, _reason} = Ogg.codec("http://station.test/stream")
    end
  end

  describe "it reads the first bytes only" do
    test "a stream longer than the limit still answers" do
      # A live stream never ends, so a whole read would never finish.
      stub(page(<<0x01, "vorbis">>) <> String.duplicate("x", 200_000))

      assert {:ok, :vorbis} = Ogg.codec("http://station.test/stream")
    end
  end
end
