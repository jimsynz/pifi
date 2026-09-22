defmodule PiFi.AirPlay.JitterBuffer do
  @moduledoc """
  Puts the audio packets back in order, and decides when to stop waiting.

  UDP delivers what it likes in whatever order it likes. A receiver that played packets
  as they arrived would play them out of order, twice, or not at all. This holds them
  briefly, hands them back in order, and — the part that matters — **decides when a
  packet that has not arrived is not going to**.

  ## Depth is latency

  Holding packets is how gaps get filled, and every packet held is delay a person hears
  between pressing play and the sound starting. `depth` is that trade written down: the
  buffer waits until it holds something that far past the gap before giving up on it.

  ## A gap is reported and not hidden

  `pop/1` answers `{:gap, count}` for packets it has given up on, rather than skipping
  quietly. Something above has to conceal them — silence, or the previous frame again —
  and that is a decision about sound rather than about ordering. **A buffer that hid
  gaps would make a stream with a bad connection sound like a stream that was simply
  fast.**

  ## Everything wraps

  Sequence numbers are sixteen bits and go round every 65536 packets. Every comparison
  here goes through `PiFi.AirPlay.Rtp.later?/2` and `distance/2` rather than through
  `<`, because the naive version decides the stream ran backwards once every
  twenty-four minutes.

  ## What it refuses to hold

  A packet older than the one due next is late and dropped: the moment for it has gone
  and holding it would put it back in the stream in the wrong place. A packet already
  held is a duplicate and dropped. A buffer at capacity drops the newest rather than
  growing, because a sender that flooded it would otherwise be given all the memory of
  a board that has 363 MB.
  """

  alias PiFi.AirPlay.Rtp

  @default_depth 128
  @default_capacity 1024

  @typedoc "Packets held, and where the reading is up to."
  @type t :: %__MODULE__{
          next: 0..65_535 | nil,
          packets: %{optional(0..65_535) => term()},
          depth: pos_integer(),
          capacity: pos_integer()
        }

  defstruct next: nil, packets: %{}, depth: @default_depth, capacity: @default_capacity

  @doc """
  An empty buffer.

  `depth` is how far past a gap it waits before giving up, and `capacity` is the most it
  will hold at once.

      iex> PiFi.AirPlay.JitterBuffer.new() |> PiFi.AirPlay.JitterBuffer.count()
      0
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      depth: Keyword.get(options, :depth, @default_depth),
      capacity: Keyword.get(options, :capacity, @default_capacity)
    }
  end

  @doc """
  How many packets are held.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{packets: packets}), do: map_size(packets)

  @doc """
  Take one packet in.

  **Nothing is late until reading has started.** The first packet to arrive is not
  necessarily the earliest one — that is the whole reason this exists — so the buffer
  takes everything until the first `pop/1`, and reading begins at the oldest it holds.
  Committing to the first arrival would drop every packet that overtook it.

      iex> buffer = PiFi.AirPlay.JitterBuffer.new()
      iex> buffer = PiFi.AirPlay.JitterBuffer.push(buffer, 7, "audio")
      iex> PiFi.AirPlay.JitterBuffer.count(buffer)
      1
  """
  @spec push(t(), 0..65_535, term()) :: t()
  def push(%__MODULE__{} = buffer, sequence, packet) do
    cond do
      Map.has_key?(buffer.packets, sequence) -> buffer
      map_size(buffer.packets) >= buffer.capacity -> buffer
      late?(buffer, sequence) -> buffer
      true -> %{buffer | packets: Map.put(buffer.packets, sequence, packet)}
    end
  end

  # **Nothing is late until reading has started.** Before the first `pop/1` there is no
  # play head to be behind, and every packet is a candidate for being the oldest.
  defp late?(%__MODULE__{next: nil}, _sequence), do: false
  defp late?(%__MODULE__{next: next}, sequence), do: Rtp.later?(next, sequence)

  @doc """
  Take the next packet out, if there is one to take.

  - `{:ok, packet, buffer}` — the packet that was due.
  - `{:gap, count, buffer}` — that many packets are not coming, and reading has moved
    past them. Something above conceals them.
  - `{:empty, buffer}` — nothing to give yet. Wait for more.
  """
  @spec pop(t()) :: {:ok, term(), t()} | {:gap, pos_integer(), t()} | {:empty, t()}
  def pop(%__MODULE__{next: nil, packets: packets} = buffer) when map_size(packets) == 0 do
    {:empty, buffer}
  end

  # **Reading starts at the oldest packet held**, not at the first that arrived.
  def pop(%__MODULE__{next: nil} = buffer), do: pop(%{buffer | next: oldest(buffer)})

  def pop(%__MODULE__{} = buffer) do
    case Map.pop(buffer.packets, buffer.next) do
      {nil, _packets} -> gap_or_wait(buffer)
      {packet, packets} -> {:ok, packet, %{buffer | packets: packets, next: after_(buffer.next)}}
    end
  end

  @doc """
  The sequence numbers between the next one due and the newest held that have not
  arrived.

  **This is what a retransmit request asks for.** It is empty for a buffer whose packets
  are in one run, which is the ordinary case.
  """
  @spec missing(t()) :: [0..65_535]
  def missing(%__MODULE__{packets: packets}) when map_size(packets) == 0, do: []

  def missing(%__MODULE__{} = buffer) do
    # Before the first `pop/1` the play head is wherever reading would start.
    from = buffer.next || oldest(buffer)

    0..Rtp.distance(newest(buffer), from)
    |> Enum.map(&Integer.mod(from + &1, 0x10000))
    |> Enum.reject(&Map.has_key?(buffer.packets, &1))
  end

  # **Give up only once something far enough past the gap has arrived.** Anything else
  # either waits for a packet that is still coming, or abandons one that was about to.
  defp gap_or_wait(%__MODULE__{} = buffer) do
    case newest(buffer) do
      nil ->
        {:empty, buffer}

      newest ->
        ahead = Rtp.distance(newest, buffer.next)

        if ahead >= buffer.depth do
          skipped = skip_to_first_held(buffer)

          {:gap, skipped, %{buffer | next: Integer.mod(buffer.next + skipped, 0x10000)}}
        else
          {:empty, buffer}
        end
    end
  end

  # How many in a row are absent, so a gap is reported once rather than one at a time.
  defp skip_to_first_held(%__MODULE__{} = buffer) do
    Enum.reduce_while(1..buffer.capacity, 1, fn offset, _found ->
      sequence = Integer.mod(buffer.next + offset, 0x10000)

      if Map.has_key?(buffer.packets, sequence), do: {:halt, offset}, else: {:cont, offset + 1}
    end)
  end

  defp oldest(%__MODULE__{} = buffer) do
    Enum.reduce(Map.keys(buffer.packets), fn sequence, found ->
      if Rtp.later?(found, sequence), do: sequence, else: found
    end)
  end

  defp newest(%__MODULE__{packets: packets}) when map_size(packets) == 0, do: nil

  defp newest(%__MODULE__{} = buffer) do
    Enum.reduce(Map.keys(buffer.packets), fn sequence, found ->
      if Rtp.later?(sequence, found), do: sequence, else: found
    end)
  end

  defp after_(sequence), do: Integer.mod(sequence + 1, 0x10000)
end
