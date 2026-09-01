defmodule MyHiFi.AutoSyncTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.AutoSync
  alias MyHiFi.Podcast.Index
  alias MyHiFi.Settings
  alias MyHiFi.Source

  doctest MyHiFi.AutoSync, import: true

  setup do
    # A row of the settings outlives a test in this suite, so a test that reads the
    # absence of one must make that absence itself.
    forget_index()

    on_exit(fn ->
      keys =
        Enum.flat_map(AutoSync.jobs(), &[AutoSync.hours_key(&1.key), AutoSync.last_key(&1.key)])

      for name <-
            keys ++
              [
                Source.enabled_key(Source.InternetRadio),
                Source.enabled_key(Source.Podcasts),
                Index.key_setting(),
                Index.secret_setting()
              ] do
        case Settings.fetch(name) do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end
    end)

    :ok
  end

  describe "the jobs that this process runs" do
    test "each one names a key, a title, a source, an action and a period" do
      for job <- AutoSync.jobs() do
        assert is_binary(job.key)
        assert is_binary(job.title)
        assert is_binary(job.description)
        assert is_atom(job.action)
        assert job.source in MyHiFi.Source.all()
        assert is_integer(job.default_hours) and job.default_hours > 0
      end
    end

    # The section of a source draws these, and no page of its own holds them.
    test "jobs_for/1 gives the jobs of one source and no other" do
      assert [%{key: "radio"}] = AutoSync.jobs_for(Source.InternetRadio)

      assert ["podcast-refresh", "podcast-trending"] =
               Source.Podcasts |> AutoSync.jobs_for() |> Enum.map(& &1.key) |> Enum.sort()
    end

    test "no two jobs share a key, because the settings keys come from it" do
      keys = Enum.map(AutoSync.jobs(), & &1.key)

      assert keys == Enum.uniq(keys)
    end

    # `MyHiFi.Application` takes these out of the crontab that `AshOban.config/2` builds,
    # so a name that no longer matches would leave a clock running the job as well.
    test "every worker is one that AshOban really schedules" do
      crontab =
        :my_hi_fi
        |> Application.fetch_env!(:ash_domains)
        |> AshOban.config(Application.fetch_env!(:my_hi_fi, Oban))
        |> Keyword.fetch!(:plugins)
        |> Enum.find_value([], fn
          {Oban.Plugins.Cron, options} -> Keyword.get(options, :crontab, [])
          _other -> nil
        end)

      scheduled = Enum.map(crontab, fn {_cron, worker, _options} -> worker end)

      for worker <- AutoSync.workers(), do: assert(worker in scheduled)
    end
  end

  describe "the period of a job" do
    test "a job that no person changed holds its own default" do
      for job <- AutoSync.jobs(), do: assert(AutoSync.hours(job.key) == job.default_hours)
    end

    test "a value that a person set comes back" do
      assert :ok = AutoSync.set_hours("radio", 48)

      assert AutoSync.hours("radio") == 48
    end

    test "0 turns the job off" do
      assert :ok = AutoSync.set_hours("radio", 0)

      assert AutoSync.hours("radio") == 0
    end

    test "a period outside the range changes nothing" do
      assert {:error, :out_of_range} = AutoSync.set_hours("radio", -1)
      assert {:error, :out_of_range} = AutoSync.set_hours("radio", 100_000)
      assert {:error, :out_of_range} = AutoSync.set_hours("radio", "a day")

      assert AutoSync.hours("radio") == 168
    end

    test "a name that no job holds changes nothing" do
      assert {:error, :no_such_job} = AutoSync.set_hours("nonsense", 4)
    end

    # A later firmware may write a value that this one cannot read.
    test "a stored value that is not a number gives the default" do
      Settings.put!(AutoSync.hours_key("radio"), "every week")

      assert AutoSync.hours("radio") == 168
    end
  end

  describe "the source that a job belongs to" do
    test "a job of a source that a person turned off is never due" do
      assert AutoSync.due?("radio")

      {:ok, :ok} = MyHiFi.Playback.enable_source(Source.InternetRadio, false)

      refute AutoSync.due?("radio")
    end

    # The index signs every request, so a device with no key reaches nothing at all and
    # a job that can only fail must never go in the queue.
    test "a job of a source that holds no key is never due" do
      refute Source.ready?(Source.Podcasts)

      refute AutoSync.due?("podcast-trending")

      configure_index()

      assert Source.ready?(Source.Podcasts)
      assert AutoSync.due?("podcast-trending")
    end

    # `function_exported?/3` alone answers false for a module that no call has loaded
    # yet, so this asks after the module is certainly loaded. `MyHiFi.Source.ready?/1`
    # uses the same guard, and it gave `true` for every source until it did.
    test "a source that names no ready? of its own is ready" do
      Code.ensure_loaded!(Source.InternetRadio)

      refute function_exported?(Source.InternetRadio, :ready?, 0)
      assert Source.ready?(Source.InternetRadio)
    end
  end

  describe "due?/2" do
    test "a job that never ran is due, which is what fills a new device" do
      assert AutoSync.last_run("radio") == nil
      assert AutoSync.due?("radio")
    end

    test "a job whose period is 0 is never due" do
      :ok = AutoSync.set_hours("radio", 0)

      refute AutoSync.due?("radio")
    end

    test "a job that ran inside its period is not due" do
      now = DateTime.utc_now()
      Settings.put!(AutoSync.last_key("radio"), DateTime.to_iso8601(now))

      refute AutoSync.due?("radio", DateTime.add(now, 167, :hour))
    end

    test "a job that ran longer ago than its period is due" do
      now = DateTime.utc_now()
      Settings.put!(AutoSync.last_key("radio"), DateTime.to_iso8601(now))

      assert AutoSync.due?("radio", DateTime.add(now, 168, :hour))
    end

    test "a stored time that this firmware cannot read counts as never run" do
      Settings.put!(AutoSync.last_key("radio"), "last Tuesday")

      assert AutoSync.last_run("radio") == nil
      assert AutoSync.due?("radio")
    end
  end

  describe "run_due/1" do
    test "it runs every job of a device that never synced" do
      configure_index()

      assert keys = AutoSync.run_due()

      assert Enum.sort(keys) == AutoSync.jobs() |> Enum.map(& &1.key) |> Enum.sort()
    end

    test "it runs nothing for a source that holds no key" do
      keys = AutoSync.run_due()

      assert keys == ["radio"]
    end

    test "it writes the time, so the second call runs nothing" do
      now = DateTime.utc_now()

      assert AutoSync.run_due(now) != []
      assert AutoSync.run_due(now) == []
    end

    test "it leaves a job that is off alone" do
      configure_index()
      :ok = AutoSync.set_hours("radio", 0)

      keys = AutoSync.run_due()

      refute "radio" in keys
      assert "podcast-refresh" in keys
    end

    test "a job runs again once its period passed" do
      now = DateTime.utc_now()
      assert "radio" in AutoSync.run_due(now)

      refute "radio" in AutoSync.run_due(DateTime.add(now, 167, :hour))
      assert "radio" in AutoSync.run_due(DateTime.add(now, 168, :hour))
    end

    # The time goes down before the job goes in the queue, because Oban cannot hold two
    # of these to one: its SQLite engine compares the arguments as JSON and AshOban puts
    # `tenant: nil` in them.
    test "it records the time that it used and not the time that it finished" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      AutoSync.run_due(now)

      assert DateTime.compare(AutoSync.last_run("radio"), now) == :eq
    end
  end

  defp configure_index do
    Settings.put!(Index.key_setting(), "a-key")
    Settings.put!(Index.secret_setting(), "a-secret")
  end

  defp forget_index do
    for name <- [Index.key_setting(), Index.secret_setting()] do
      case Settings.fetch(name) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end
  end
end
