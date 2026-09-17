defmodule PiFi.Device.StorageUsageTest do
  use PiFi.DataCase, async: false

  alias PiFi.Cache
  alias PiFi.Device
  alias PiFi.Playback

  describe "the kinds of media" do
    test "a download counts against the source that gave it" do
      hold_audio("podcasts", "https://a.test/one.mp3", 400)
      hold_audio("jellyfin", "https://a.test/two.flac", 900)

      assert bytes_of("podcasts") == 400
      assert bytes_of("jellyfin") == 900
    end

    test "two downloads of one source count together" do
      hold_audio("podcasts", "https://a.test/one.mp3", 400)
      hold_audio("podcasts", "https://a.test/two.mp3", 600)

      assert bytes_of("podcasts") == 1000
    end

    test "the artwork of the cache is a kind of its own" do
      Cache.put!("artwork", "cover", %{bytes: String.duplicate("c", 700)})

      assert bytes_of("artwork") == 700
    end

    # **The colour of a kind comes from its place in this list**, and the places are
    # measured as pairs that touch. A kind that moved would put two colours side by
    # side that no measurement covers. See `PiFiWeb.SettingsLive`.
    test "the order is fixed, and the largest kind does not come first" do
      hold_audio("podcasts", "https://a.test/one.mp3", 10)
      hold_audio("jellyfin", "https://a.test/two.flac", 10_000)
      Cache.put!("artwork", "cover", %{bytes: String.duplicate("c", 5000)})

      assert keys() == ["podcasts", "jellyfin", "artwork", "database", "other"]
    end

    test "a kind that holds no byte draws no row" do
      hold_audio("podcasts", "https://a.test/one.mp3", 400)

      refute "jellyfin" in keys()
      refute "artwork" in keys()
    end

    # A person who reads the rows must be able to add them up and reach the number that
    # the page gives for the space in use, or the bar lies about what it spans.
    test "the kinds add up to the space in use" do
      hold_audio("podcasts", "https://a.test/one.mp3", 400)
      Cache.put!("artwork", "cover", %{bytes: String.duplicate("c", 700)})

      total = Enum.sum(Enum.map(Device.storage_usage!(), & &1.bytes))

      assert total == Device.storage!().used_bytes
    end

    test "each kind names itself in words that a person reads" do
      hold_audio("podcasts", "https://a.test/one.mp3", 400)

      assert label_of("podcasts") == "Podcasts"
      assert label_of("other") == "Other"
    end
  end

  defp hold_audio(source, url, bytes) do
    item =
      Playback.upsert_item!(%{
        source: source,
        source_ref: url,
        kind: :track,
        title: "A track",
        url: url,
        transport: :download
      })

    Cache.put!("download", item.id, %{bytes: String.duplicate("a", bytes)})

    item
  end

  defp keys, do: Enum.map(Device.storage_usage!(), & &1.key)

  defp kind(key), do: Enum.find(Device.storage_usage!(), &(&1.key == key))

  defp bytes_of(key) do
    case kind(key) do
      nil -> nil
      found -> found.bytes
    end
  end

  defp label_of(key), do: kind(key).label
end
