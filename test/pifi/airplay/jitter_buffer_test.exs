defmodule PiFi.AirPlay.JitterBufferTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.JitterBuffer

  alias PiFi.AirPlay.JitterBuffer, as: Buffer

  defp push_all(buffer, pairs) do
    Enum.reduce(pairs, buffer, fn {sequence, packet}, acc ->
      Buffer.push(acc, sequence, packet)
    end)
  end

  defp drain(buffer, found \\ []) do
    case Buffer.pop(buffer) do
      {:ok, packet, next} -> drain(next, [packet | found])
      {:gap, count, next} -> drain(next, [{:gap, count} | found])
      {:empty, _next} -> Enum.reverse(found)
    end
  end

  describe "putting packets back in order" do
    test "packets that arrive in order come out in order" do
      buffer = push_all(Buffer.new(), [{1, "a"}, {2, "b"}, {3, "c"}])

      assert drain(buffer) == ["a", "b", "c"]
    end

    # This is the whole point: UDP delivers what it likes in whatever order it likes.
    test "packets that arrive out of order come out in order" do
      buffer = push_all(Buffer.new(), [{3, "c"}, {1, "a"}, {2, "b"}])

      assert drain(buffer) == ["a", "b", "c"]
    end

    test "the first packet sets where reading starts" do
      buffer = push_all(Buffer.new(), [{500, "a"}, {501, "b"}])

      assert drain(buffer) == ["a", "b"]
    end

    test "an empty buffer has nothing to give" do
      assert {:empty, _buffer} = Buffer.pop(Buffer.new())
    end
  end

  describe "what it will not hold" do
    # The moment for it has gone, and putting it back would place it wrongly.
    test "a packet older than the one due next" do
      buffer = push_all(Buffer.new(), [{5, "a"}, {6, "b"}])
      {:ok, "a", buffer} = Buffer.pop(buffer)

      buffer = Buffer.push(buffer, 5, "again")

      assert drain(buffer) == ["b"]
    end

    test "a duplicate" do
      buffer = push_all(Buffer.new(), [{1, "a"}, {1, "different"}])

      assert Buffer.count(buffer) == 1
      assert drain(buffer) == ["a"]
    end

    # A sender that flooded this would otherwise be given all the memory of a board
    # with 363 MB.
    test "more than it was told to hold" do
      buffer = Buffer.new(capacity: 4)
      buffer = push_all(buffer, Enum.map(1..20, &{&1, "packet #{&1}"}))

      assert Buffer.count(buffer) <= 4
    end
  end

  # **A buffer that hid gaps would make a bad connection sound like a fast stream.**
  describe "giving up on a packet" do
    test "it waits while the gap could still be filled" do
      buffer = Buffer.new(depth: 10)
      buffer = push_all(buffer, [{1, "a"}, {3, "c"}])

      assert {:ok, "a", buffer} = Buffer.pop(buffer)
      assert {:empty, _buffer} = Buffer.pop(buffer)
    end

    test "a late packet that arrives in time fills the gap" do
      buffer = Buffer.new(depth: 10)
      buffer = push_all(buffer, [{1, "a"}, {3, "c"}, {2, "b"}])

      assert drain(buffer) == ["a", "b", "c"]
    end

    test "it gives up once something far enough past has arrived" do
      buffer = Buffer.new(depth: 3)
      buffer = push_all(buffer, [{1, "a"}, {5, "e"}])

      assert {:ok, "a", buffer} = Buffer.pop(buffer)
      assert {:gap, 3, buffer} = Buffer.pop(buffer)
      assert {:ok, "e", _buffer} = Buffer.pop(buffer)
    end

    # A gap is reported once rather than one packet at a time, so whatever conceals it
    # knows how much to conceal.
    test "one gap is reported once with its length" do
      buffer = Buffer.new(depth: 2)
      buffer = push_all(buffer, [{1, "a"}, {6, "f"}])

      assert drain(buffer) == ["a", {:gap, 4}, "f"]
    end
  end

  # **Sixteen bits wrap every 65536 packets.** Every comparison goes through the RTP
  # helpers rather than through `<`.
  describe "across the wrap" do
    test "packets in order across zero come out in order" do
      pairs = Enum.map([65_534, 65_535, 0, 1], &{&1, "packet #{&1}"})

      assert drain(push_all(Buffer.new(), pairs)) == Enum.map(pairs, &elem(&1, 1))
    end

    # **Reading starts at the oldest held and not at the first that arrived**, so the
    # order they turn up in must not matter — including when the oldest is on the far
    # side of zero from the newest.
    test "out of order across zero comes back in order whatever order it arrived" do
      pairs = [{65_535, "last"}, {0, "zero"}, {1, "one"}]

      for arrival <- [
            pairs,
            Enum.reverse(pairs),
            [Enum.at(pairs, 1) | [Enum.at(pairs, 2), Enum.at(pairs, 0)]]
          ] do
        assert drain(push_all(Buffer.new(), arrival)) == ["last", "zero", "one"],
               "failed for arrival order #{inspect(Enum.map(arrival, &elem(&1, 0)))}"
      end
    end

    test "a gap that spans zero" do
      buffer = Buffer.new(depth: 2)
      buffer = push_all(buffer, [{65_534, "a"}, {2, "e"}])

      assert {:ok, "a", buffer} = Buffer.pop(buffer)
      assert {:gap, 3, buffer} = Buffer.pop(buffer)
      assert {:ok, "e", _buffer} = Buffer.pop(buffer)
    end

    test "a late packet across zero is still refused" do
      buffer = push_all(Buffer.new(), [{0, "a"}, {1, "b"}])
      {:ok, "a", buffer} = Buffer.pop(buffer)

      buffer = Buffer.push(buffer, 65_530, "ancient")

      assert drain(buffer) == ["b"]
    end
  end

  # This is what a retransmit request asks for.
  describe "what is missing" do
    test "nothing, for packets in one run" do
      assert Buffer.missing(push_all(Buffer.new(), [{1, "a"}, {2, "b"}, {3, "c"}])) == []
    end

    test "the holes between the next due and the newest held" do
      buffer = push_all(Buffer.new(), [{1, "a"}, {4, "d"}])

      assert Buffer.missing(buffer) == [2, 3]
    end

    test "nothing, for an empty buffer" do
      assert Buffer.missing(Buffer.new()) == []
    end

    test "holes across the wrap" do
      buffer = push_all(Buffer.new(), [{65_535, "a"}, {2, "d"}])

      assert Buffer.missing(buffer) == [0, 1]
    end
  end
end
