defmodule PiFi.AirPlay.Alac do
  @moduledoc """
  Turns the audio a telephone sends into samples this device can play.

  **AirPlay 2 sends ALAC and nothing on Hex decodes it.** The decoder in
  `c_src/pifi/alac` is David Hammerton's, under the MIT licence — the same one every
  AirPlay receiver uses, including Shairport Sync. It is one file of about a thousand
  lines and it needs no library beside it, which is why it is here rather than a Rust NIF
  or another precompiled dependency: Bundlex already cross-compiles the Membrane decoders
  for this board, so this is the toolchain the project has.

  ## It is not the upstream file, and the changes are the point

  **That decoder was written to read files, and this one reads a network.** It trusts its
  input completely: `alac_decode_frame` took no input length at all, so it read the
  bitstream until the bitstream said to stop, and a frame that arrived corrupt sent it
  off the end of the packet and into whatever followed it in memory. It runs inside the
  BEAM, so that is the whole firmware.

  Feeding it damaged frames under AddressSanitizer found five ways out of its own
  buffers, and `c_src/pifi/alac/alac.c` carries a comment at each one:

    * the readers had no input length, and now take one and give zeroes past the end;
    * a huge bit count walked the read position far enough past the end to overflow the
      pointer and wrap back below it, so the position is pinned to the frame;
    * a zero-run length off the wire was `memset` into a buffer without checking it fit;
    * the predictor's warm-up loop ran for as many coefficients as the frame claimed,
      which overruns the buffers of a short frame;
    * a sample count off the wire was checked only after being multiplied into an `int`
      that it overflows.

  `start/1` refuses the configurations that make the remaining arithmetic unsafe, because
  the sender picks those numbers too. The fuzzing lives in the test beside this, so a
  version of the decoder that loses these checks fails rather than going quiet.

  None of it changes what a correct frame decodes to: the test decodes a file `ffmpeg`
  encoded and compares every byte against what `ffmpeg` decodes it back to.

  ## A decoder belongs to a stream

  `start/1` makes one and `decode/2` feeds it. The decoder holds the rice parameters and
  the working buffers of one stream, so making a new one for each frame would throw that
  away and allocate on every packet of the audio. **One session, one decoder.**

  ## The configuration comes from the sender

  A sender names the frame length, the bit depth and the rice parameters in its `SETUP`,
  as twenty-four bytes the specification calls the magic cookie. Nothing here guesses
  them: a receiver that assumed 4096 frames of sixteen bits would decode noise from a
  sender that said otherwise, and it would decode it confidently.

  ## What it does with a frame it cannot read

  Nothing, and it says so. `decode/2` answers `{:ok, <<>>}` for a frame the decoder
  could not use, because a packet lost or corrupted on the way is a gap in the audio and
  not a reason to end a session — `PiFi.AirPlay.JitterBuffer` already reports the gaps,
  and something above conceals them.
  """

  alias PiFi.AirPlay.Alac.Native

  @config_bytes 24
  @max_frame_length 4096
  @max_channels 2

  @typedoc "A decoder for one stream. It is a resource of the NIF and not a process."
  @opaque t :: reference()

  @doc """
  The twenty-four byte configuration, read into the parts a sender named.

  Useful for saying what a stream is, and for refusing one this cannot play before any
  audio arrives rather than after.

      iex> config = <<0, 0, 16, 0, 0, 16, 40, 10, 14, 2, 0, 0, 0, 0, 64, 4,
      ...>            0, 21, 136, 128, 0, 0, 172, 68>>
      iex> PiFi.AirPlay.Alac.describe(config)
      {:ok, %{frame_length: 4096, bit_depth: 16, channels: 2, sample_rate: 44100}}

  Anything that is not twenty-four bytes is refused rather than read as far as it goes.

      iex> PiFi.AirPlay.Alac.describe(<<0, 0, 16, 0>>)
      {:error, :bad_config}
  """
  @spec describe(binary()) :: {:ok, map()} | {:error, :bad_config}
  def describe(
        <<frame_length::32, _compatible, bit_depth, _pb, _mb, _kb, channels, _max_run::16,
          _max_frame_bytes::32, _average_bit_rate::32, sample_rate::32>>
      ) do
    {:ok,
     %{
       frame_length: frame_length,
       bit_depth: bit_depth,
       channels: channels,
       sample_rate: sample_rate
     }}
  end

  def describe(_config), do: {:error, :bad_config}

  @doc """
  A decoder for one stream, from the configuration its sender gave.

  **Everything in the configuration comes from the sender, and each part of it is
  checked here.** A depth `sample_format/1` will not name is refused because the decoder
  answers such a stream with the contents of an untouched buffer rather than with an
  error. The frame length is refused above #{@max_frame_length} because every working
  buffer of the decoder is sized from it and the decoder's own overflow checks multiply
  it in an `int`, which a large value wraps — so an absurd length there turns those
  checks into ones that pass.
  """
  @spec start(binary()) :: {:ok, t()} | {:error, term()}
  def start(config) when byte_size(config) == @config_bytes do
    with {:ok, described} <- describe(config),
         :ok <- supported(described) do
      Native.start(config, described.bit_depth, described.channels)
    end
  rescue
    ArgumentError -> {:error, :bad_config}
  end

  def start(_config), do: {:error, :bad_config}

  @doc """
  Decode one frame into interleaved samples.

  The samples are little-endian and as wide as the configuration said, so a stream of
  sixteen bits gives what `Membrane.RawAudio` calls `:s16le`.
  """
  @spec decode(t(), binary()) :: {:ok, binary()} | {:error, term()}
  def decode(decoder, frame) when is_binary(frame) do
    Native.decode(decoder, frame)
  rescue
    ArgumentError -> {:error, :bad_frame}
  end

  @doc """
  How wide one sample is, for the format the pipeline is told about.

      iex> PiFi.AirPlay.Alac.sample_format(16)
      {:ok, :s16le}

      iex> PiFi.AirPlay.Alac.sample_format(24)
      {:ok, :s24le}

  **Sixteen and twenty-four are the only depths this decodes**, and the limit is the
  decoder rather than the codec. The `switch` on `setinfo_sample_size` in `alac.c` writes
  samples for those two and falls through for twenty and thirty-two, which leaves the
  output buffer untouched while still reporting a length — so a stream in either of those
  would play whatever the buffer held last, rather than failing. Refusing them here is
  what keeps that from reaching a speaker.

      iex> PiFi.AirPlay.Alac.sample_format(32)
      {:error, {:unsupported_depth, 32}}

      iex> PiFi.AirPlay.Alac.sample_format(12)
      {:error, {:unsupported_depth, 12}}
  """
  @spec sample_format(pos_integer()) :: {:ok, atom()} | {:error, term()}
  def sample_format(16), do: {:ok, :s16le}
  def sample_format(24), do: {:ok, :s24le}
  def sample_format(depth), do: {:error, {:unsupported_depth, depth}}

  defp supported(%{frame_length: length}) when length < 1 or length > @max_frame_length,
    do: {:error, {:unsupported_frame_length, length}}

  defp supported(%{channels: channels}) when channels < 1 or channels > @max_channels,
    do: {:error, {:unsupported_channels, channels}}

  defp supported(%{bit_depth: depth}) do
    with {:ok, _format} <- sample_format(depth), do: :ok
  end

  defmodule Native do
    @moduledoc false

    use Bundlex.Loader, nif: :alac

    @spec start(binary(), integer(), integer()) :: {:ok, reference()}
    defnif(start(config, sample_size, channels))

    @spec decode(reference(), binary()) :: {:ok, binary()}
    defnif(decode(decoder, frame))
  end
end
