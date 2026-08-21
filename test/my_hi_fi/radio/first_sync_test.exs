defmodule MyHiFi.Radio.FirstSyncTest do
  use MyHiFi.DataCase, async: false
  use Oban.Testing, repo: MyHiFi.Repo

  alias MyHiFi.Radio
  alias MyHiFi.Radio.FirstSync
  alias MyHiFi.Radio.Station.Workers.SyncFromRemote

  defp station do
    Radio.upsert_station_from_remote!(%{
      remote_id: "remote-#{System.unique_integer([:positive])}",
      title: "A station",
      stream_url: "http://example.test/stream.mp3",
      codec: "MP3",
      bitrate: 128,
      hls?: false,
      country_code: "NZ",
      tags: [],
      click_count: 0
    })
  end

  describe "run/0" do
    test "asks for the station list when the table holds nothing" do
      # A new device would hold no station until the weekly run, and that run comes
      # at the end of the week.
      assert FirstSync.run() == :ok
      assert_enqueued(worker: SyncFromRemote)
    end

    test "asks for nothing when the table holds a station" do
      station()

      assert FirstSync.run() == :ok
      refute_enqueued(worker: SyncFromRemote)
    end
  end

  describe "child_spec/1" do
    test "runs once and then stops, so the tree does not start it again" do
      spec = FirstSync.child_spec(nil)

      assert spec.id == FirstSync
      assert spec.restart == :temporary
      assert {Task, :start_link, [_function]} = spec.start
    end
  end
end
