defmodule PiFi.Playback.ItemTest do
  use PiFi.DataCase, async: false

  alias PiFi.Cache
  alias PiFi.Playback
  alias PiFi.Playback.Item
  alias PiFi.Player.Download

  defp item(overrides \\ %{}) do
    Playback.upsert_item!(
      Map.merge(
        %{
          source: "internet-radio",
          source_ref: "station-#{System.unique_integer([:positive])}",
          kind: :track,
          title: "A station",
          url: "http://example.test/stream.mp3",
          transport: :http,
          format: :mp3,
          live?: true
        },
        overrides
      )
    )
  end

  # The audio of a track that a person is in the middle of, as `PiFi.Player.Download`
  # writes it.
  defp hold_audio(item) do
    Cache.put(Download.namespace(), item.id, %{
      bytes: "some audio",
      content_type: "audio/mpeg",
      keep?: true
    })
  end

  describe "what identifies an item" do
    test "the source and its name there make one row" do
      first = item(%{source_ref: "the-same", title: "First"})
      second = item(%{source_ref: "the-same", title: "Second"})

      assert first.id == second.id
      assert second.title == "Second"
      assert Ash.count!(Item) == 1
    end

    test "two sources can use the same name" do
      radio = item(%{source: "internet-radio", source_ref: "one"})
      podcast = item(%{source: "podcasts", source_ref: "one"})

      refute radio.id == podcast.id
      assert Ash.count!(Item) == 2
    end

    # A service knows nothing of what a person did, so a second read must not remove
    # a mark or a place.
    test "a second read leaves what a person did alone" do
      created = item(%{source_ref: "keep-me", keeps_place?: true})
      {:ok, _marked} = Playback.set_favourite(created)
      {:ok, _placed} = Playback.store_position(created, %{position_ms: 42_000})

      _again = item(%{source_ref: "keep-me", title: "A new title", keeps_place?: true})

      assert {:ok, read} = Playback.get_item(created.id)
      assert read.title == "A new title"
      assert read.favourite? == true
      assert read.position_ms == 42_000
    end
  end

  describe "a container and what it holds" do
    test "an item names the container that holds it" do
      show = item(%{kind: :container, source: "podcasts", source_ref: "show", title: "A show"})
      episode = item(%{source: "podcasts", source_ref: "one", parent_id: show.id})

      assert [found] = Playback.items_of_parent!(show.id)
      assert found.id == episode.id
    end

    test "an item with no picture of its own uses the one of its container" do
      show =
        item(%{
          kind: :container,
          source: "podcasts",
          source_ref: "show",
          artwork_url: "https://example.test/cover.jpg"
        })

      bare = item(%{source: "podcasts", source_ref: "bare", parent_id: show.id})

      own =
        item(%{
          source: "podcasts",
          source_ref: "own",
          parent_id: show.id,
          artwork_url: "https://example.test/episode.jpg"
        })

      assert {:ok, bare} = Playback.get_item(bare.id, load: [:artwork])
      assert bare.artwork == "https://example.test/cover.jpg"

      assert {:ok, own} = Playback.get_item(own.id, load: [:artwork])
      assert own.artwork == "https://example.test/episode.jpg"
    end

    test "an item with no container and no picture holds none" do
      created = item()

      assert {:ok, read} = Playback.get_item(created.id, load: [:artwork])
      assert read.artwork == nil
    end
  end

  describe "what a person did" do
    test "a mark goes on and comes off" do
      created = item()

      assert {:ok, marked} = Playback.set_favourite(created)
      assert marked.favourite? == true
      assert [found] = Playback.favourite_items!()
      assert found.id == created.id

      assert {:ok, cleared} = Playback.clear_favourite(marked)
      assert cleared.favourite? == false
      assert Playback.favourite_items!() == []
    end

    test "an item that keeps its place holds the time and the byte" do
      created = item(%{keeps_place?: true})

      assert {:ok, placed} =
               Playback.store_position(created, %{position_ms: 90_000, position_bytes: 1_440_000})

      assert placed.position_ms == 90_000
      assert placed.position_bytes == 1_440_000
    end

    # A person who stops half way through an episode goes on from there next week. A
    # person who stops half way through a song does not want the second half of it
    # tomorrow.
    test "an item that keeps no place takes none, and it reports no error" do
      created = item(%{keeps_place?: false})

      assert {:ok, placed} =
               Playback.store_position(created, %{position_ms: 90_000, position_bytes: 1_440_000})

      assert placed.position_ms == 0
      assert placed.position_bytes == nil
    end

    # The player tells every item where a person stopped, so a song must not stop it.
    test "an item keeps no place by default" do
      assert item().keeps_place? == false
    end

    # The place of a track that ended is its start, so a person who plays it again
    # hears it from the beginning.
    test "the end of a track removes the place" do
      created = item(%{keeps_place?: true})
      {:ok, placed} = Playback.store_position(created, %{position_ms: 90_000, position_bytes: 14})

      assert {:ok, played} = Playback.mark_played(placed)
      assert played.played? == true
      assert played.position_ms == 0
      assert played.position_bytes == nil
      assert played.last_played_at
    end

    # A track that a person is in the middle of holds its file against every eviction,
    # and a track that they are done with holds nothing. See
    # `PiFi.Playback.Item.Changes.ReleaseAudio`.
    test "the mark lets an eviction take the file of the track" do
      created = item(%{keeps_place?: true})
      {:ok, _entry} = hold_audio(created)

      assert {:ok, _played} = Playback.mark_played(created)
      assert {:ok, %{keep?: false}} = Cache.fetch(Download.namespace(), created.id)
    end

    # A person who marked an episode by mistake, and a person who wants to hear one
    # again, press the same control.
    test "a person takes the mark off" do
      created = item(%{keeps_place?: true})
      {:ok, played} = Playback.mark_played(created)

      assert {:ok, cleared} = Playback.clear_played(played)
      assert cleared.played? == false
      assert cleared.position_ms == 0
    end
  end

  describe "the order that a list reads in" do
    # SQLite compares text byte by byte, so every capital letter comes in front of
    # every small one and a person who looked under A found the albums of a band with
    # a small first letter at the end of Z.
    test "a sort of sorted_title reads the letters and not the bytes" do
      for title <- ["Zabriskie Point", "alt-J", "Antics"] do
        item(%{source_ref: title, title: title})
      end

      titles =
        Item
        |> Ash.Query.for_read(:read)
        |> Ash.Query.sort(sorted_title: :asc)
        |> Ash.read!()
        |> Enum.map(& &1.title)

      assert titles == ["alt-J", "Antics", "Zabriskie Point"]
    end

    # `PiFi.Player.Queue` holds the place of the track that plays as a keyset, and a
    # keyset of a calculation holds the value that the calculation gave.
    test "a keyset of that order holds the place of a row" do
      for title <- ["Zabriskie Point", "alt-J", "Antics"] do
        item(%{source_ref: title, title: title})
      end

      query =
        Item
        |> Ash.Query.for_read(:read)
        |> Ash.Query.sort(sorted_title: :asc)

      assert [%{title: "alt-J"} = first] = Ash.read!(Ash.Query.page(query, limit: 1)).results

      assert [%{title: "Antics"}] =
               query
               |> Ash.Query.page(after: first.__metadata__.keyset, limit: 1)
               |> Ash.read!()
               |> Map.fetch!(:results)
    end
  end

  describe "reading a list" do
    test "it lists the items of one source" do
      item(%{source: "internet-radio", source_ref: "a"})
      item(%{source: "internet-radio", source_ref: "b"})
      item(%{source: "podcasts", source_ref: "c"})

      assert length(Playback.items_of_source!("internet-radio")) == 2
      assert length(Playback.items_of_source!("podcasts")) == 1
    end

    # `PiFi.Player.Queue` holds the place of the track that plays as a keyset, so a
    # move reads one row and it stays right when the list changes.
    test "a read gives a keyset, and a page after it holds the next row" do
      for title <- ["Alpha", "Bravo", "Charlie"] do
        item(%{source_ref: title, title: title})
      end

      page =
        Item
        |> Ash.Query.for_read(:read)
        |> Ash.Query.sort(title: :asc)
        |> Ash.Query.page(limit: 1)
        |> Ash.read!()

      assert [%{title: "Alpha"} = first] = page.results

      after_first =
        Item
        |> Ash.Query.for_read(:read)
        |> Ash.Query.sort(title: :asc)
        |> Ash.Query.page(after: first.__metadata__.keyset, limit: 1)
        |> Ash.read!()

      assert [%{title: "Bravo"} = second] = after_first.results

      before_second =
        Item
        |> Ash.Query.for_read(:read)
        |> Ash.Query.sort(title: :asc)
        |> Ash.Query.page(before: second.__metadata__.keyset, limit: 1)
        |> Ash.read!()

      assert [%{title: "Alpha"}] = before_second.results
    end

    test "a read past the last row gives nothing, which is the end of a list" do
      created = item(%{title: "The only one"})

      page =
        Item
        |> Ash.Query.for_read(:read)
        |> Ash.Query.sort(title: :asc)
        |> Ash.Query.page(limit: 1)
        |> Ash.read!()

      assert [only] = page.results
      assert only.id == created.id

      past =
        Item
        |> Ash.Query.for_read(:read)
        |> Ash.Query.sort(title: :asc)
        |> Ash.Query.page(after: only.__metadata__.keyset, limit: 1)
        |> Ash.read!()

      assert past.results == []
    end
  end
end
