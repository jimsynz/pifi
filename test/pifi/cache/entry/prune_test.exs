defmodule PiFi.Cache.Entry.PruneTest do
  @moduledoc """
  How the cache decides what goes first.

  A card fills, and what it drops decides what a person sees. The tier this replaced
  emptied the artwork of a library while tracks nobody had played in months sat there.
  """

  use ExUnit.Case, async: true

  doctest PiFi.Cache.Entry.Prune

  alias PiFi.Cache.Entry.Prune

  @now ~U[2026-01-31 00:00:00Z]

  defp entry(days_ago, weight) do
    %{last_accessed_at: DateTime.add(@now, -days_ago * 86_400, :second), weight: weight}
  end

  defp order(entries), do: entries |> Enum.sort_by(&Prune.score(&1, @now), :desc)

  describe "what goes first" do
    # The whole point. A picture the device fetches again by itself goes before a track
    # that is there so it plays when the server is off.
    test "a cheap thing goes before an expensive thing of the same age" do
      picture = entry(10, 0)
      track = entry(10, 1)

      assert order([track, picture]) == [picture, track]
    end

    # **This is what the tier got wrong.** It read `weight` as an order, so no amount of
    # age let a track go before a picture, and a library's artwork emptied while stale
    # audio stayed.
    test "an expensive thing that is cold enough goes before a fresh cheap one" do
      ancient_track = entry(365, 1)
      todays_picture = entry(1, 0)

      assert order([todays_picture, ancient_track]) == [ancient_track, todays_picture]
    end

    test "a track has to be twice as cold as a picture to lose to it" do
      picture = entry(7, 0)
      track = entry(14, 1)

      assert Prune.score(picture, @now) == Prune.score(track, @now)
    end

    # A shade under twice is not enough, which is the boundary of the rule above.
    test "a track that is not quite twice as cold stays" do
      picture = entry(7, 0)
      track = entry(13, 1)

      assert order([track, picture]) == [picture, track]
    end

    test "of two things that cost the same, the colder goes" do
      older = entry(30, 1)
      newer = entry(2, 1)

      assert order([newer, older]) == [older, newer]
    end
  end

  describe "the ends of the range" do
    # **A write that never got a mark is a file no reader wants.** It has to sort ahead
    # of every number, and `:infinity` is an atom, which Elixir orders above every
    # number — this test is here so that stays true rather than being relied on quietly.
    test "an entry nothing ever read goes before everything" do
      never = %{last_accessed_at: nil, weight: 9}
      ancient = entry(3650, 0)

      assert Prune.score(never, @now) == :infinity
      assert order([ancient, never]) == [never, ancient]
    end

    test "something read this instant is the last thing to go" do
      assert Prune.score(%{last_accessed_at: @now, weight: 0}, @now) == 0.0
    end

    # A clock that went backwards, or a row written a moment in the future. It must not
    # rank ahead of things that are genuinely cold.
    test "a time in the future scores below anything real" do
      future = %{last_accessed_at: DateTime.add(@now, 60, :second), weight: 0}

      assert Prune.score(future, @now) < 0
      assert order([future, entry(1, 0)]) == [entry(1, 0), future]
    end

    test "a heavier weight always scores lower than a lighter one of the same age" do
      for weight <- 1..5 do
        assert Prune.score(entry(10, weight), @now) < Prune.score(entry(10, weight - 1), @now)
      end
    end
  end
end
