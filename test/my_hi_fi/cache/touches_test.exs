defmodule MyHiFi.Cache.TouchesTest do
  @moduledoc """
  The used marks of the cache, held in memory and written together.

  `MyHiFi.Application` starts no buffer in the test environment, because the sandbox
  gives the connection of the database to the process of the test. Each test here
  therefore starts its own, and it runs alone for that reason.
  """

  use MyHiFi.DataCase, async: false

  alias MyHiFi.Cache
  alias MyHiFi.Cache.Touches

  @png <<0x89, "PNG\r\n", 0x1A, "\n", "the rest of a small image">>

  setup do
    # A read of an entry of the last hour writes no row, and every entry that a test
    # writes is of the last second. See `MyHiFi.Cache.used/1`.
    Application.put_env(:my_hi_fi, :cache_touch_after_seconds, 0)

    on_exit(fn ->
      Application.delete_env(:my_hi_fi, :cache_touch_after_seconds)
      File.rm_rf(Cache.directory())
    end)

    :ok
  end

  defp entry(key) do
    Cache.put!("artwork", key, %{bytes: @png, content_type: "image/png"})
  end

  defp mark_of(key) do
    {:ok, entry} = Cache.fetch("artwork", key)

    entry.last_accessed_at
  end

  describe "with no buffer running" do
    # This is what every other test of the cache reads, and it is what a host build
    # does.
    test "a read writes the row at once" do
      one = entry("one")
      before = one.last_accessed_at

      Process.sleep(5)
      assert :ok = Cache.used(one)

      assert DateTime.compare(mark_of("one"), before) == :gt
    end

    test "a flush answers, because there is nothing to wait for" do
      assert :ok = Touches.flush()
    end
  end

  describe "with the buffer running" do
    setup do
      start_supervised!({Touches, debounce_ms: 50, ceiling_ms: 5_000})

      :ok
    end

    test "a read writes no row of its own" do
      one = entry("one")
      before = one.last_accessed_at

      Process.sleep(5)
      assert :ok = Cache.used(one)

      assert mark_of("one") == before
    end

    test "the marks reach the card when the reads stop" do
      one = entry("one")
      before = mark_of("one")

      Process.sleep(5)
      Cache.used(one)

      assert eventually(fn -> DateTime.compare(mark_of("one"), before) == :gt end)
    end

    # One statement for the whole buffer is the point of it: 25 acquisitions of the
    # write lock of the card become one.
    test "many reads of many entries write together" do
      entries = for key <- ~w(one two three), do: entry(key)
      before = Map.new(~w(one two three), &{&1, mark_of(&1)})

      Process.sleep(5)
      for one <- entries, _again <- 1..3, do: Cache.used(one)

      assert :ok = Touches.flush()

      for key <- ~w(one two three) do
        assert DateTime.compare(mark_of(key), before[key]) == :gt, "#{key} kept its mark"
      end
    end

    test "a flush writes what the buffer holds, and waits for it" do
      one = entry("one")
      before = mark_of("one")

      Process.sleep(5)
      Cache.used(one)

      assert :ok = Touches.flush()
      assert DateTime.compare(mark_of("one"), before) == :gt
    end

    # **A debounce alone can wait for ever**, because the timeout of a GenServer starts
    # again with each message. A person browsing a library sends one of these every few
    # hundred milliseconds, and the ceiling is what puts the marks on the card anyway.
    test "the ceiling writes the marks while the reads continue" do
      stop_supervised!(Touches)
      start_supervised!({Touches, debounce_ms: 10_000, ceiling_ms: 100})

      one = entry("one")
      before = mark_of("one")

      Process.sleep(5)

      task =
        Task.async(fn ->
          Enum.each(1..40, fn _each ->
            Cache.used(one)
            Process.sleep(20)
          end)
        end)

      assert eventually(fn -> DateTime.compare(mark_of("one"), before) == :gt end)

      Task.await(task)
    end

    # A restart of the firmware keeps what the buffer knew.
    test "it writes what it holds when it stops" do
      one = entry("one")
      before = mark_of("one")

      Process.sleep(5)
      Cache.used(one)

      stop_supervised!(Touches)

      assert DateTime.compare(mark_of("one"), before) == :gt
    end
  end

  # The write happens in the process of the buffer, so a test waits for it and does not
  # sleep for a period that a slow machine makes wrong.
  defp eventually(check, attempts \\ 100)

  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end
end
