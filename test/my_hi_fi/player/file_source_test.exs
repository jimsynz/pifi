defmodule MyHiFi.Player.FileSourceTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Player.FileSource
  alias MyHiFi.Player.FileSource.State

  @buffer_bytes 10

  setup do
    path = Path.join(System.tmp_dir!(), "file_source_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)
    {:ok, path: path}
  end

  # `available` is what the download says the file holds, and it is not always what
  # the file holds: the message arrives after the write.
  defp playing(path, contents, overrides \\ %{}) do
    File.write!(path, contents)
    {:ok, device} = :file.open(path, [:read, :binary, :raw])

    Map.merge(
      %State{
        key: "episode-1",
        uri: "https://example.test/episode.mp3",
        device: device,
        available: byte_size(contents),
        buffer_bytes: @buffer_bytes,
        filling?: false
      },
      overrides
    )
  end

  defp payloads(actions) do
    for {:buffer, {:output, %Membrane.Buffer{payload: payload}}} <- actions,
        into: <<>>,
        do: payload
  end

  defp ended?(actions), do: Enum.member?(actions, {:end_of_stream, :output})

  describe "the demand unit" do
    test "the pad asks in bytes, and the callback answers in bytes", %{path: path} do
      state = playing(path, "some audio")

      assert {actions, _state} = FileSource.handle_demand(:output, 4, :bytes, nil, state)
      assert payloads(actions) == "some"
    end
  end

  describe "the file fills before anything leaves" do
    test "a file under the limit gives no buffer", %{path: path} do
      state = playing(path, "short", %{filling?: true, demand: 500})

      assert {[], _state} = FileSource.handle_demand(:output, 0, :bytes, nil, state)
    end

    test "a file that holds enough begins to play", %{path: path} do
      state = playing(path, "long enough for the limit", %{filling?: true})

      assert {actions, _state} = FileSource.handle_demand(:output, 4, :bytes, nil, state)
      assert payloads(actions) == "long"
    end

    test "a whole file plays whatever its size, because nothing more is coming", %{path: path} do
      state = playing(path, "tiny", %{filling?: true, whole?: true})

      assert {actions, _state} = FileSource.handle_demand(:output, 4, :bytes, nil, state)
      assert payloads(actions) == "tiny"
    end
  end

  describe "reading" do
    test "it reads from the place that it holds", %{path: path} do
      state = playing(path, "0123456789", %{offset: 4})

      assert {actions, state} = FileSource.handle_demand(:output, 3, :bytes, nil, state)
      assert payloads(actions) == "456"
      assert state.offset == 7
    end

    test "a demand larger than the file gives what the file holds", %{path: path} do
      state = playing(path, "0123456789")

      assert {actions, state} = FileSource.handle_demand(:output, 500, :bytes, nil, state)
      assert payloads(actions) == "0123456789"
      assert state.demand == 490
    end

    # `Membrane.MP3.MAD.Decoder` decodes a whole input buffer in one callback, so a
    # buffer of a whole episode asks it for 822 MB of samples on a board that holds
    # 363.9 MB. One read on the board did that, and a person heard noise.
    test "no buffer is larger than the limit, whatever the demand", %{path: path} do
      contents = :binary.copy("a", 40 * 1024)
      state = playing(path, contents)

      assert {actions, state} = FileSource.handle_demand(:output, 40 * 1024, :bytes, nil, state)

      assert byte_size(payloads(actions)) == 16 * 1024
      assert state.offset == 16 * 1024
    end

    test "a demand that one buffer cannot fill asks for another turn", %{path: path} do
      state = playing(path, :binary.copy("a", 40 * 1024))

      assert {actions, _state} = FileSource.handle_demand(:output, 40 * 1024, :bytes, nil, state)

      assert Enum.member?(actions, {:redemand, :output})
    end

    test "a demand that one buffer fills asks for no other turn", %{path: path} do
      state = playing(path, "0123456789")

      assert {actions, _state} = FileSource.handle_demand(:output, 4, :bytes, nil, state)

      refute Enum.member?(actions, {:redemand, :output})
    end

    test "it reads no further than the download says, whatever the file holds", %{path: path} do
      # The file holds ten bytes and the last message said four. Reading past that
      # would read bytes that no message has named yet.
      state = playing(path, "0123456789", %{available: 4})

      assert {actions, _state} = FileSource.handle_demand(:output, 500, :bytes, nil, state)
      assert payloads(actions) == "0123"
    end
  end

  describe "the end of the file" do
    test "the end of a whole file ends the stream", %{path: path} do
      state = playing(path, "0123456789", %{whole?: true})

      assert {actions, _state} = FileSource.handle_demand(:output, 500, :bytes, nil, state)
      assert payloads(actions) == "0123456789"
      assert ended?(actions)
    end

    test "the end of a file that still grows ends nothing", %{path: path} do
      state = playing(path, "0123456789", %{whole?: false})

      assert {actions, _state} = FileSource.handle_demand(:output, 500, :bytes, nil, state)
      assert payloads(actions) == "0123456789"
      refute ended?(actions)
    end

    test "a demand at the end of a whole file ends the stream and reads nothing", %{path: path} do
      state = playing(path, "0123456789", %{whole?: true, offset: 10})

      assert {actions, _state} = FileSource.handle_demand(:output, 500, :bytes, nil, state)
      assert payloads(actions) == ""
      assert ended?(actions)
    end

    test "a demand at the end of a growing file waits", %{path: path} do
      state = playing(path, "0123456789", %{whole?: false, offset: 10})

      assert {[], _state} = FileSource.handle_demand(:output, 500, :bytes, nil, state)
    end
  end

  describe "what the download says" do
    test "more bytes wake a reader that had nothing to give", %{path: path} do
      state = playing(path, "0123456789", %{available: 4, offset: 4, demand: 500})

      assert {actions, state} =
               FileSource.handle_info({:download, {:bytes, 10}}, nil, state)

      assert payloads(actions) == "456789"
      assert state.available == 10
    end

    test "a file that is whole ends the stream when the reader reaches its end", %{path: path} do
      state = playing(path, "0123456789", %{available: 4, offset: 4, demand: 500})

      assert {actions, state} = FileSource.handle_info({:download, :done}, nil, state)

      assert payloads(actions) == "456789"
      assert ended?(actions)
      assert state.whole? == true
    end

    # The size comes from the open file and not from its name, because the download
    # moves the file into the cache at the moment that it finishes.
    test "the whole size comes from the file that it holds open", %{path: path} do
      state = playing(path, "0123456789", %{available: 0, demand: 500})
      File.rename!(path, path <> ".moved")
      on_exit(fn -> File.rm_rf(path <> ".moved") end)

      assert {actions, state} = FileSource.handle_info({:download, :done}, nil, state)

      assert payloads(actions) == "0123456789"
      assert state.available == 10
    end

    test "a download that fails stops the pipeline", %{path: path} do
      state = playing(path, "0123456789")

      assert_raise RuntimeError, ~r/could not be read|Could not read/, fn ->
        FileSource.handle_info({:download, {:error, :closed}}, nil, state)
      end
    end

    test "it holds no opinion about any other message", %{path: path} do
      state = playing(path, "0123456789")

      assert {[], ^state} = FileSource.handle_info(:something_else, nil, state)
    end
  end

  describe "where a resume begins" do
    @header <<0xFF, 0xFB, 0x90, 0x00>>
    @frame_bytes 417

    defp mp3(count) do
      :binary.copy(@header <> :binary.copy(<<0>>, @frame_bytes - 4), count)
    end

    defp device(path, contents) do
      File.write!(path, contents)
      {:ok, device} = :file.open(path, [:read, :binary, :raw])
      device
    end

    # The byte that a resume holds is in front of what a person heard, because the
    # pipeline holds a lead over the sound. A read on the board measured 3.8 s of
    # lead, which is 61 KB of a 128 kbit/s episode.
    test "it steps back, so a person hears a little again and loses no word", %{path: path} do
      device = device(path, mp3(2000))
      held = 1000 * @frame_bytes

      assert FileSource.rewound(held, device, :mp3) <= held - 96 * 1024
    end

    test "it lands on a frame boundary, so MAD skips nothing", %{path: path} do
      device = device(path, mp3(2000))

      assert FileSource.rewound(1000 * @frame_bytes, device, :mp3)
             |> rem(@frame_bytes) == 0
    end

    test "a track at the start begins at the start", %{path: path} do
      device = device(path, mp3(2000))

      assert FileSource.rewound(0, device, :mp3) == 0
    end

    test "a place inside the margin begins at the start", %{path: path} do
      device = device(path, mp3(2000))

      assert FileSource.rewound(1000, device, :mp3) == 0
    end

    # A file that holds no frame where this looked still plays, because the step back
    # is what stops a person from losing a word.
    test "bytes that hold no frame still step back", %{path: path} do
      device = device(path, :binary.copy(<<0>>, 400_000))

      assert FileSource.rewound(300_000, device, :mp3) == 300_000 - 96 * 1024
    end

    # AAC holds frames of another shape, so `MyHiFi.Player.Mp3Frame` must not read it.
    test "another codec steps back and aligns nothing", %{path: path} do
      device = device(path, mp3(2000))

      assert FileSource.rewound(300_000, device, :aac) == 300_000 - 96 * 1024
    end
  end

  describe "a resume" do
    # This is the property that makes a resume exact. The person stopped at byte
    # 40_000 of a file that the download has not reached, so the reader waits for
    # that byte instead of beginning somewhere near it.
    test "a place that the download has not reached waits for it", %{path: path} do
      state = playing(path, "0123456789", %{available: 4, offset: 8, demand: 500})

      assert {[], state} = FileSource.handle_demand(:output, 0, :bytes, nil, state)
      assert state.offset == 8

      assert {actions, _state} = FileSource.handle_info({:download, {:bytes, 10}}, nil, state)
      assert payloads(actions) == "89"
    end
  end
end
