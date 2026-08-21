defmodule MyHiFi.PersistentLoggerTest do
  use ExUnit.Case, async: true

  alias MyHiFi.PersistentLogger

  setup do
    directory = Path.join(System.tmp_dir!(), "myhifi_log_#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    # `:file` and `:device` are reserved names in an ExUnit context.
    {:ok,
     log_path: Path.join(directory, "myhifi.log"), device_path: Path.join(directory, "pmsg0")}
  end

  defp config(context, overrides \\ %{}) do
    %{
      config:
        Map.merge(
          %{
            device: context.device_path,
            file: context.log_path,
            file_max_bytes: 256 * 1024
          },
          overrides
        )
    }
  end

  defp event(message, level \\ :info) do
    %{level: level, msg: {:string, message}, meta: %{time: 1_700_000_000_000_000}}
  end

  describe "log/2" do
    test "writes the line to both places", context do
      PersistentLogger.log(event("the device started"), config(context))

      assert File.read!(context.log_path) =~ "the device started"
      assert File.read!(context.device_path) =~ "the device started"
    end

    test "holds the level and the time", context do
      PersistentLogger.log(event("a fault", :error), config(context))

      line = File.read!(context.log_path)

      assert line =~ "error"
      assert line =~ "2023-11-14"
    end

    test "cuts a long message for the small window, and not for the file", context do
      long = String.duplicate("x", 3000)
      PersistentLogger.log(event(long), config(context))

      assert byte_size(File.read!(context.log_path)) > 3000
      assert byte_size(File.read!(context.device_path)) < 600
    end

    test "each line ends, so one entry cannot run into the next", context do
      PersistentLogger.log(event(String.duplicate("y", 3000)), config(context))
      PersistentLogger.log(event("the next line"), config(context))

      assert File.read!(context.device_path) |> String.split("\n", trim: true) |> length() == 2
      assert File.read!(context.log_path) |> String.split("\n", trim: true) |> length() == 2
    end

    test "a report and a format both become text", context do
      PersistentLogger.log(
        %{level: :info, msg: {:report, %{what: "a report"}}, meta: %{}},
        config(context)
      )

      PersistentLogger.log(
        %{level: :info, msg: {~c"a format ~p", [:value]}, meta: %{}},
        config(context)
      )

      log = File.read!(context.log_path)

      assert log =~ "a report"
      # Erlang writes an atom with `~p` and no colon in front of it.
      assert log =~ "a format value"
    end

    test "an event of another shape writes nothing", context do
      assert PersistentLogger.log(%{unexpected: true}, config(context)) == :ok
      refute File.exists?(context.log_path)
    end
  end

  describe "the limit of the file" do
    test "the old lines go to the second file, and the new ones start again",
         context do
      settings = config(context, %{file_max_bytes: 200})

      PersistentLogger.log(event(String.duplicate("a", 300)), settings)
      PersistentLogger.log(event("after the limit"), settings)

      assert File.read!(context.log_path) =~ "after the limit"
      assert File.read!(context.log_path <> ".1") =~ String.duplicate("a", 300)
    end

    test "read/1 gives the older lines first" do
      directory =
        Path.join(System.tmp_dir!(), "myhifi_read_#{System.unique_integer([:positive])}")

      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf(directory) end)

      path = Path.join(directory, "myhifi.log")
      File.write!(path <> ".1", "the older line\n")
      File.write!(path, "the newer line\n")

      assert {:ok, "the older line\nthe newer line\n"} = PersistentLogger.read(path)
    end

    test "read/1 gives an error when no file is there" do
      assert {:error, :enoent} =
               PersistentLogger.read(Path.join(System.tmp_dir!(), "no_such_log"))
    end
  end

  describe "a place that cannot take a write" do
    test "a log line never stops the firmware", context do
      settings = config(context, %{file: "/no/such/directory/myhifi.log"})

      assert PersistentLogger.log(event("this still answers"), settings) == :ok
    end
  end
end
