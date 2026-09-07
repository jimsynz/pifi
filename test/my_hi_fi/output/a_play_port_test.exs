defmodule MyHiFi.Output.APlayPortTest do
  @moduledoc """
  The process that holds `aplay` across more than one pipeline.

  It is one process for the whole node, and `MyHiFi.Application` starts it, so these
  tests use that one and each of them gives the port back. `cat` takes the place of
  `aplay`: this module holds no knowledge of ALSA, and the arguments are the name of
  the sound and nothing more.
  """

  use ExUnit.Case, async: false

  alias MyHiFi.Output.APlayPort

  setup do
    on_exit(fn -> APlayPort.close() end)

    :ok
  end

  describe "hold/2" do
    test "it opens a program and holds it" do
      assert {:ok, port} = APlayPort.hold("cat", [])

      assert Port.info(port)
      assert APlayPort.held() == {"cat", []}
    end

    # **This is what removes the gap between two tracks of one album.** A start of
    # `aplay` opens the sound card and holds a silence of about one second.
    test "the same arguments again give the same port" do
      assert {:ok, first} = APlayPort.hold("cat", ["--rate=44100"])
      assert {:ok, second} = APlayPort.hold("cat", ["--rate=44100"])

      assert second == first
    end

    # The format of the audio is on the command line of `aplay`, so a track of another
    # rate needs another program. A station at 24000 Hz after a track at 44100 Hz is
    # the case that this covers.
    test "other arguments end the program and open another" do
      assert {:ok, first} = APlayPort.hold("cat", ["--rate=44100"])
      assert {:ok, second} = APlayPort.hold("cat", ["--rate=24000"])

      assert second != first
      refute Port.info(first)
      assert Port.info(second)
      assert APlayPort.held() == {"cat", ["--rate=24000"]}
    end

    test "a program that this system holds nowhere gives an error" do
      assert {:error, {:no_program, "no-such-program-of-this-firmware"}} =
               APlayPort.hold("no-such-program-of-this-firmware", [])
    end
  end

  describe "close/0" do
    test "it ends the program, so the room is quiet" do
      {:ok, port} = APlayPort.hold("cat", [])

      assert :ok = APlayPort.close()

      refute Port.info(port)
      assert APlayPort.held() == nil
    end

    test "it answers a caller that holds no program" do
      assert :ok = APlayPort.close()
      assert :ok = APlayPort.close()
    end
  end

  describe "a program that ends by itself" do
    test "the holder forgets it, so the next call opens another" do
      {:ok, port} = APlayPort.hold("sh", ["-c", "exit 3"])

      assert eventually(fn -> APlayPort.held() == nil end)
      refute Port.info(port)

      assert {:ok, another} = APlayPort.hold("cat", [])
      assert another != port
    end
  end

  # **A process that does not own a port may write to it.** The sink is that process,
  # and this is the fact that lets one program outlive the pipeline that plays through
  # it.
  describe "the port that a stranger writes to" do
    test "a write from another process reaches the program" do
      {:ok, port} = APlayPort.hold("cat", [])

      task = Task.async(fn -> Port.command(port, "some samples") end)

      assert Task.await(task)
      assert eventually(fn -> Port.info(port, :output) == {:output, 12} end)
    end
  end

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
