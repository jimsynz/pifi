defmodule PiFi.AirPlay.PlaybackSourceTest do
  @moduledoc """
  The whole receiving path, end to end, against audio something else made.

  **This is the first test that joins all of it**: real datagrams over a real UDP socket,
  ChaCha20-Poly1305 off each one, the jitter buffer putting them in order, and the ALAC
  decoder turning them into samples. What comes out is compared against what `ffmpeg`
  decodes the same file to, byte for byte.

  The frames are `test/fixtures/alac/sine440.packets`, the fixture
  `PiFi.AirPlay.AlacTest` uses. They are 4096 frames each rather than the 352 a realtime
  sender uses, which is why the configuration is named rather than defaulted — the point
  is the path, and this is the only real ALAC this project has.
  """

  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias Membrane.RawAudio
  alias PiFi.AirPlay.Alac
  alias PiFi.AirPlay.AudioSocket
  alias PiFi.AirPlay.PlaybackSource

  @digest "b62b778352be6523642c0d1ed3318ce375d98191d0879e12c1201e6d7558734b"
  @samples 44_100

  @config Alac.config(frame_length: 4096)

  defp frames do
    "test/fixtures/alac/sine440.packets"
    |> File.read!()
    |> Stream.unfold(fn
      <<>> ->
        nil

      <<size::32, rest::binary>> ->
        <<frame::binary-size(^size), tail::binary>> = rest
        {frame, tail}
    end)
    |> Enum.to_list()
  end

  defp sealed(audio, key, sequence) do
    short = :crypto.strong_rand_bytes(8)
    timestamp = sequence * 4096
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

  defp playing(options \\ []) do
    key = :crypto.strong_rand_bytes(32)

    {:ok, socket} =
      start_supervised({AudioSocket, Keyword.merge([key: key], Keyword.take(options, [:depth]))})

    {:ok, port} = AudioSocket.port(socket)
    {:ok, sender} = :gen_udp.open(0, [:binary])

    on_exit(fn -> :gen_udp.close(sender) end)

    {[], state} =
      PlaybackSource.handle_init(nil, %{
        socket: socket,
        config: Keyword.get(options, :config, @config)
      })

    {actions, state} = PlaybackSource.handle_playing(nil, state)

    %{
      state: state,
      actions: actions,
      socket: socket,
      key: key,
      send: &:gen_udp.send(sender, {127, 0, 0, 1}, port, &1)
    }
  end

  defp payloads(actions) do
    for {:buffer, {:output, %Buffer{payload: payload}}} <- actions, into: <<>>, do: payload
  end

  defp arrived(socket, count) do
    eventually(fn -> AudioSocket.statistics(socket).received >= count end)
  end

  # The element asks again when the socket is dry, so reading everything means answering
  # that ask as the pipeline would.
  defp drained(state, taken \\ <<>>, rounds \\ 20)
  defp drained(state, taken, 0), do: {taken, state}

  defp drained(state, taken, rounds) do
    {actions, state} = PlaybackSource.handle_info(:take, nil, state)

    case payloads(actions) do
      <<>> ->
        Process.sleep(10)
        drained(state, taken, rounds - 1)

      more ->
        drained(state, taken <> more, rounds - 1)
    end
  end

  describe "the format it announces" do
    test "says what the configuration said" do
      %{actions: actions} = playing()

      assert [stream_format: {:output, format}] = actions

      assert format == %RawAudio{channels: 2, sample_rate: 44_100, sample_format: :s16le}
    end

    # A realtime sender sends no cookie at all, so this is the one a receiver has to
    # already know.
    test "a session that named no configuration gets the realtime one" do
      %{actions: actions} = playing(config: nil)

      assert [stream_format: {:output, format}] = actions
      assert format.sample_rate == 44_100
    end

    # Better here than on a telephone. A stream this cannot decode has no format to
    # announce, and carrying on would send the pipeline samples that are not samples.
    test "a configuration it cannot decode stops rather than playing noise" do
      {:ok, socket} = start_supervised({AudioSocket, key: :crypto.strong_rand_bytes(32)})

      {[], state} =
        PlaybackSource.handle_init(nil, %{
          socket: socket,
          config: Alac.config(bit_depth: 32)
        })

      assert_raise RuntimeError, ~r/cannot be decoded/, fn ->
        PlaybackSource.handle_playing(nil, state)
      end
    end
  end

  describe "audio that a sender sent" do
    # **The whole path, checked against ffmpeg.** Every earlier test in this directory
    # checks one link of it.
    test "comes out as the samples ffmpeg decodes it to" do
      %{state: state, socket: socket, key: key, send: send} = playing()

      frames = frames()

      for {frame, sequence} <- Enum.with_index(frames) do
        send.(sealed(frame, key, sequence))
      end

      assert arrived(socket, length(frames))

      {actions, state} = PlaybackSource.handle_demand(:output, @samples, :bytes, nil, state)
      {rest, _state} = drained(state)

      pcm = payloads(actions) <> rest

      assert byte_size(pcm) == @samples
      assert :crypto.hash(:sha256, pcm) |> Base.encode16(case: :lower) == @digest
    end

    test "arrives in order even when the packets did not" do
      %{state: state, socket: socket, key: key, send: send} = playing()

      frames = frames()

      for {frame, sequence} <- frames |> Enum.with_index() |> Enum.reverse() do
        send.(sealed(frame, key, sequence))
      end

      assert arrived(socket, length(frames))

      {actions, state} = PlaybackSource.handle_demand(:output, @samples, :bytes, nil, state)
      {rest, _state} = drained(state)

      assert :crypto.hash(:sha256, payloads(actions) <> rest) |> Base.encode16(case: :lower) ==
               @digest
    end
  end

  describe "when nothing has arrived" do
    # **A demand that never answers stops the pipeline**, so this has to come back and
    # ask again rather than waiting inside the demand.
    test "it asks again rather than blocking" do
      %{state: state} = playing()

      assert {[], state} = PlaybackSource.handle_demand(:output, 1_000, :bytes, nil, state)
      assert state.asking?
      assert_receive :take, 200
    end

    # A demand arriving while one ask is already out must not start a second, or the
    # asking doubles every time the socket runs dry.
    test "one ask is outstanding at a time" do
      %{state: state} = playing()

      {[], state} = PlaybackSource.handle_demand(:output, 1_000, :bytes, nil, state)
      {[], _state} = PlaybackSource.handle_demand(:output, 1_000, :bytes, nil, state)

      assert_receive :take, 200
      refute_receive :take, 100
    end

    test "nothing is asked for when nothing is demanded" do
      %{state: state} = playing()

      assert {[], state} = PlaybackSource.handle_info(:take, nil, state)
      refute state.asking?
    end
  end

  describe "a gap in the audio" do
    # **Silence of exactly the length that was lost.** A gap filled with nothing at all
    # pulls everything after it earlier, and a sender's idea of where it is in the track
    # slowly stops matching what a person hears.
    test "becomes silence as long as the packets that went missing" do
      %{state: state, socket: socket, key: key, send: send} = playing(depth: 4)

      [first, _second, third] = frames()

      send.(sealed(first, key, 0))
      # 2 never comes, and the buffer gives up once it holds far enough past it.
      for sequence <- 2..40, do: send.(sealed(third, key, sequence))

      assert arrived(socket, 40)

      {actions, state} = PlaybackSource.handle_demand(:output, @samples * 4, :bytes, nil, state)
      {rest, _state} = drained(state)

      pcm = payloads(actions) <> rest
      frame_bytes = 4096 * 2 * 2

      # The first frame, then silence where the second should have been, then the third.
      assert binary_part(pcm, frame_bytes, frame_bytes) == :binary.copy(<<0>>, frame_bytes)
      assert binary_part(pcm, 0, frame_bytes) != :binary.copy(<<0>>, frame_bytes)
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
