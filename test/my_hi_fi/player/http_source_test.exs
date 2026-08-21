defmodule MyHiFi.Player.HttpSourceTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Player.HttpSource
  alias MyHiFi.Player.HttpSource.State
  alias MyHiFi.Player.IcyStream

  @buffer_bytes 1000

  # A state that has already filled its buffer, so a test can ask for bytes.
  defp playing(overrides) do
    Map.merge(
      %State{
        uri: "http://radio.test/stream",
        buffer_bytes: @buffer_bytes,
        icy: IcyStream.new(nil),
        filling?: false
      },
      overrides
    )
  end

  defp filling(overrides) do
    playing(Map.merge(%{filling?: true}, overrides))
  end

  defp payloads(actions) do
    for {:buffer, {:output, %Membrane.Buffer{payload: payload}}} <- actions,
        into: <<>>,
        do: payload
  end

  describe "the demand unit" do
    test "the pad asks in bytes, and the callback answers in bytes" do
      # An earlier version held no `demand_unit: :bytes`, so this clause never
      # matched, nothing left the element, and the board ran out of memory.
      state = playing(%{queue: "some audio"})

      assert {actions, _state} = HttpSource.handle_demand(:output, 4, :bytes, nil, state)
      assert payloads(actions) == "some"
    end
  end

  describe "the buffer fills before anything leaves" do
    test "a queue under the limit gives no buffer" do
      state = filling(%{queue: String.duplicate("a", @buffer_bytes - 1), demand: 5000})

      assert {[], _state} = HttpSource.handle_demand(:output, 0, :bytes, nil, state)
    end

    test "a queue at the limit starts to give buffers" do
      state = filling(%{queue: String.duplicate("a", @buffer_bytes), demand: 0})

      assert {actions, state} = HttpSource.handle_demand(:output, 100, :bytes, nil, state)
      assert byte_size(payloads(actions)) == 100
      refute state.filling?
    end

    test "it stays filled once it filled, so a short queue later still gives bytes" do
      state = playing(%{queue: "short"})

      assert {actions, _state} = HttpSource.handle_demand(:output, 100, :bytes, nil, state)
      assert payloads(actions) == "short"
    end
  end

  describe "serving what the queue holds" do
    test "gives no more than the queue" do
      state = playing(%{queue: "only this"})

      assert {actions, state} = HttpSource.handle_demand(:output, 9999, :bytes, nil, state)
      assert payloads(actions) == "only this"
      assert state.queue == <<>>
    end

    test "keeps the demand that it could not answer" do
      state = playing(%{queue: "12345"})

      assert {_actions, state} = HttpSource.handle_demand(:output, 100, :bytes, nil, state)
      assert state.demand == 95
    end

    test "adds each demand to the one before it" do
      state = playing(%{queue: <<>>, demand: 40})

      assert {[], state} = HttpSource.handle_demand(:output, 60, :bytes, nil, state)
      assert state.demand == 100
    end

    test "an empty queue gives nothing and raises nothing" do
      state = playing(%{queue: <<>>})

      assert {[], _state} = HttpSource.handle_demand(:output, 500, :bytes, nil, state)
    end
  end

  describe "the end of a stream" do
    test "an empty queue that is done ends the stream" do
      state = playing(%{queue: <<>>, done?: true, demand: 100})

      assert {[end_of_stream: :output], _state} =
               HttpSource.handle_demand(:output, 0, :bytes, nil, state)
    end

    test "the last bytes go before the end" do
      state = playing(%{queue: "the last bytes", done?: true})

      assert {actions, _state} = HttpSource.handle_demand(:output, 9999, :bytes, nil, state)
      assert payloads(actions) == "the last bytes"
      assert Enum.member?(actions, {:end_of_stream, :output})
    end

    test "a queue that still holds bytes does not end the stream" do
      state = playing(%{queue: "more to come", done?: true})

      assert {actions, _state} = HttpSource.handle_demand(:output, 4, :bytes, nil, state)
      refute Enum.member?(actions, {:end_of_stream, :output})
    end

    test "a stream that ends while the buffer fills still ends" do
      # A station that answers with less than one buffer must not hold the device.
      state = filling(%{queue: "a short answer", done?: true, demand: 100})

      assert {actions, _state} = HttpSource.handle_demand(:output, 0, :bytes, nil, state)
      assert Enum.member?(actions, {:end_of_stream, :output})
    end
  end

  describe "trim/1" do
    test "leaves a queue that is inside the limit" do
      queue = String.duplicate("a", @buffer_bytes * 8)
      state = playing(%{queue: queue})

      assert HttpSource.trim(state).queue == queue
    end

    test "drops the oldest audio past the limit, and keeps one buffer" do
      # This is the guard that stopped the board from running out of memory when
      # nothing downstream asked for bytes.
      queue = String.duplicate("o", @buffer_bytes) <> String.duplicate("n", @buffer_bytes * 8)
      state = playing(%{queue: queue})

      trimmed = HttpSource.trim(state)

      assert byte_size(trimmed.queue) == @buffer_bytes * 8
      # The oldest bytes went, so nothing of the first buffer is left.
      refute String.contains?(trimmed.queue, "o")
    end

    test "a queue far past the limit gives up one buffer for each call" do
      # One call drops one buffer, and not everything past the limit. That is safe
      # because a call comes with each chunk from the network: a chunk holds a few
      # kilobytes, and a buffer holds 64 KB on the device, so the queue shrinks far
      # faster than it grows. Do not read this as a queue that stays too large.
      state = playing(%{queue: String.duplicate("x", @buffer_bytes * 40)})

      assert byte_size(HttpSource.trim(state).queue) == @buffer_bytes * 39

      shrunk =
        Enum.reduce(1..35, state, fn _call, state -> HttpSource.trim(state) end)

      assert byte_size(shrunk.queue) <= @buffer_bytes * 8
    end

    test "an empty queue is inside the limit" do
      assert HttpSource.trim(playing(%{queue: <<>>})).queue == <<>>
    end
  end

  describe "handle_info" do
    test "a message that Req does not know changes nothing" do
      state = playing(%{queue: "held"})

      assert {[], ^state} = HttpSource.handle_info(:something_else, nil, state)
    end

    test "a message before the request changes nothing" do
      state = playing(%{response: nil})

      assert {[], ^state} = HttpSource.handle_info({:tcp, :socket, "data"}, nil, state)
    end
  end

  describe "handle_init" do
    test "holds the options of the element" do
      options = %{
        uri: "http://radio.test/stream",
        headers: [{"x-test", "1"}],
        buffer_bytes: 4096
      }

      assert {[], state} = HttpSource.handle_init(nil, options)
      assert state.uri == "http://radio.test/stream"
      assert state.headers == [{"x-test", "1"}]
      assert state.buffer_bytes == 4096
      assert state.filling?
      assert state.queue == <<>>
    end
  end
end
