defmodule PiFiWeb.ItemListTest do
  @moduledoc """
  The row of a list, and the facts that a source names for it.

  A source says which facts a row draws, and this module holds the drawing of each one.
  See `c:PiFi.Source.listing/1`.
  """

  use ExUnit.Case, async: true

  alias PiFi.Playback.Item
  alias PiFiWeb.ItemList

  doctest PiFiWeb.ItemList, import: true

  defp item(attributes), do: struct(Item, attributes)

  describe "place_text/1" do
    test "a track of one disc reads as its number" do
      assert ItemList.place_text(item(number: 7)) == "7"
    end

    # Track 1 of disc 2 comes after track 12 of disc 1, and the number alone cannot say
    # that.
    test "a track of a set names the disc" do
      assert ItemList.place_text(item(number: 1, disc: 2)) == "2-01"
      assert ItemList.place_text(item(number: 12, disc: 1)) == "1-12"
    end

    # A publisher that names no episode number gets none. See
    # `PiFi.Podcast.Feed.Parser`.
    test "an item with no place reads as nothing" do
      assert ItemList.place_text(item(%{})) == nil
    end
  end

  describe "fact/2" do
    test "a duration reads as minutes and seconds" do
      assert ItemList.fact(:duration_ms, item(duration_ms: 367_000)) == "6:07"
      assert ItemList.fact(:duration_ms, item(duration_ms: 3_723_000)) == "1:02:03"
    end

    test "a live stream and an item of no length draw no duration" do
      assert ItemList.fact(:duration_ms, item(duration_ms: nil)) == nil
      assert ItemList.fact(:duration_ms, item(duration_ms: 0)) == nil
    end

    # **An episode that no person began reads as a length**, because `remaining_ms` is
    # the whole duration of one and "1h left" of an episode that nobody touched says the
    # wrong thing.
    test "an episode says how much is left, and a fresh one says how long it is" do
      began = item(duration_ms: 3_600_000, position_ms: 960_000, remaining_ms: 2_640_000)
      fresh = item(duration_ms: 3_600_000, position_ms: 0, remaining_ms: 3_600_000)

      assert ItemList.fact(:remaining_ms, began) == "44m left"
      assert ItemList.fact(:remaining_ms, fresh) == "1:00:00"
    end

    test "an episode that reached its end says so" do
      assert ItemList.fact(:remaining_ms, item(played?: true)) == "Played"
    end

    test "a time left of more than an hour reads as hours and minutes" do
      assert ItemList.fact(:remaining_ms, item(duration_ms: 9_000_000, remaining_ms: 4_500_000)) ==
               "1h 15m left"

      assert ItemList.fact(:remaining_ms, item(duration_ms: 9_000_000, remaining_ms: 7_200_000)) ==
               "2h left"
    end

    # A person reads a podcast of this week and the year says nothing. An album of 2013
    # needs it.
    test "a date of this year holds no year, and an older one does" do
      this_year = DateTime.utc_now() |> DateTime.add(-2, :day)

      assert ItemList.fact(:published_at, item(published_at: this_year)) ==
               Calendar.strftime(this_year, "%-d %B")

      assert ItemList.fact(:published_at, item(published_at: ~U[2013-09-24 00:00:00Z])) ==
               "24 September 2013"
    end

    test "an album release year reads as four digits" do
      assert ItemList.fact(:release_year, item(release_year: 1998)) == "1998"
    end

    test "a fact of no value draws nothing, so a row draws no separator for it" do
      assert ItemList.fact(:subtitle, item(subtitle: nil)) == nil
      assert ItemList.fact(:published_at, item(published_at: nil)) == nil
      assert ItemList.fact(:release_year, item(release_year: nil)) == nil
      assert ItemList.fact(:remaining_ms, item(%{})) == nil
    end

    # A surface that meets a fact it does not know draws nothing, and never an error.
    test "a fact that this module does not know draws nothing" do
      assert ItemList.fact(:something_new, item(title: "A track")) == nil
    end
  end

  describe "audio/2" do
    test "a file that the card holds draws the mark" do
      assert ItemList.audio(%{}, item(id: "one", audio_held?: true)) == :held
    end

    # The read that drew the list said what the card held then, and a file that arrived
    # after it reaches the map alone.
    test "the map wins over the row" do
      row = item(id: "one", audio_held?: false)

      assert ItemList.audio(%{"one" => :held}, row) == :held

      assert ItemList.audio(%{"one" => {:reading, 500}}, item(id: "one", byte_size: 2000)) ==
               "25%"
    end

    test "a share needs the size of the file, and a row without one still says it reads" do
      row = item(id: "one", byte_size: nil)

      assert ItemList.audio(%{"one" => {:reading, 500}}, row) == "Reading"
    end

    test "a share never passes the whole" do
      row = item(id: "one", byte_size: 1000)

      assert ItemList.audio(%{"one" => {:reading, 1200}}, row) == "100%"
    end

    test "a file that this device does not hold draws nothing" do
      assert ItemList.audio(%{}, item(id: "one", audio_held?: false)) == nil
      assert ItemList.audio(%{"one" => :absent}, item(id: "one", audio_held?: false)) == nil
    end

    # A list that names no calculation holds `%Ash.NotLoaded{}` there, and it must not
    # fail for that.
    test "a row that never read the calculation draws nothing" do
      assert ItemList.audio(%{}, item(id: "one")) == nil
    end
  end
end
