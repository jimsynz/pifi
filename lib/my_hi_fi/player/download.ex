defmodule MyHiFi.Player.Download do
  @moduledoc """
  Reads one podcast episode onto the disk as fast as the network allows.

  A live radio stream arrives at about the bitrate of the audio, so the wire gives
  the pacing and `MyHiFi.Player.HttpSource` needs none of its own. A podcast server
  sends a whole file at the speed of the network, and that broke the sound: the
  queue of the element passed its limit and the guard dropped the oldest audio 1259
  times during one read of a 49.7 MB episode.

  This process therefore holds no audio in memory. It writes each part to a file,
  and `MyHiFi.Player.FileSource` reads that file while it grows. A file needs no
  flow control.

  ## Where the file goes

  It writes `<partial>/<episode id>`, and `<partial>` is a directory beside the
  cache on the data partition. When the file is whole it goes into the cache with
  `MyHiFi.Cache.put_file/3`, which moves it. **Both paths must sit on one
  partition**, because that move is `File.rename/2`.

  The file waits outside the cache while it grows, because
  `MyHiFi.Cache.Entry.Changes.Write` names a row that names a file that exists. A
  file whose size changes would make the accounting of the cache wrong, and an
  eviction reads that accounting.

  ## The life of a download

  **A stop of the playback does not end it.** The request is already in flight, and
  a content delivery network often sends the whole file before a person stops. It
  therefore holds no link to the pipeline. It finishes the file, it puts the entry
  in the cache, and it stops by itself. A later play of that episode then reads a
  whole local file, so it asks the network for nothing and it begins at once.

  A download that an interruption stops leaves a file that no row names, so no
  eviction can see it and the cache cannot reclaim it. `sweep/0` is what keeps those
  files from filling the partition, and `MyHiFi.Application` calls it at each boot.
  A file of the last day stays, because a play of that episode reads what it holds
  and asks for the rest with a `range` header.

  ## What a watcher hears

  A watcher gets `{:download, {:bytes, count}}` as the file grows,
  `{:download, :done}` when the file is whole and in the cache, and
  `{:download, {:error, reason}}` when it is not.
  """

  use GenServer, restart: :temporary

  require Logger

  alias MyHiFi.Cache
  alias MyHiFi.Event
  alias MyHiFi.Event.Source, as: Events

  # Sobelow reads `@sobelow_skip` from the source. This registration stops the
  # compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @keep_partial_hours 24
  # How often a page hears that the file grew. See `announce/1`.
  @announce_ms 1_000

  @namespace "download"
  @directory "partial"
  @registry MyHiFi.Player.Download.Registry
  @supervisor MyHiFi.Player.Download.Supervisor
  @timeout :timer.seconds(60)
  @user_agent "MyHiFi/0.1 (+https://harton.dev/mypihifiguy/myhifi)"

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            uri: String.t(),
            path: String.t(),
            request: reference() | nil,
            written: non_neg_integer(),
            watchers: [pid()],
            told_at: integer() | nil,
            done?: boolean()
          }

    defstruct [:id, :uri, :path, :request, :told_at, written: 0, watchers: [], done?: false]
  end

  @doc """
  Everything that a reader needs to play one episode.

  It gives the path of the whole file when the cache holds it, and it starts a
  download when the cache does not. A second call for one episode finds the first
  download and starts no other.

  The caller becomes a watcher of the download as this starts it, so it hears every
  message. A caller that asked first and subscribed second would miss the whole
  download of a small episode.

  The reader opens whichever of the two paths exists, because a download that
  finishes between this answer and that open moves the file from one to the other.
  """
  @spec ensure(String.t(), String.t()) ::
          {:ok, %{paths: [Path.t()], complete?: boolean()}} | {:error, term()}
  def ensure(id, uri), do: ensure(id, uri, 2)

  defp ensure(_id, _uri, 0), do: {:error, :cannot_start}

  defp ensure(id, uri, tries) do
    case Cache.fetch(@namespace, id) do
      {:ok, entry} -> complete(entry)
      {:error, _reason} -> start_or_join(id, uri, tries)
    end
  end

  @doc "Where a file waits while it grows."
  @spec directory() :: Path.t()
  def directory do
    MyHiFi.Device.storage!().path |> Path.join(@directory) |> Path.expand()
  end

  @doc "The namespace that the cache holds an episode under."
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc """
  Let an eviction take the file of an episode.

  A download holds `keep?`, because one file of 50 MB would otherwise remove 50
  covers and a list of shows would remove the episode that a person is in the middle
  of. An episode that reached its end is no longer that, so it becomes the coldest
  thing in the cache and the eviction may take it.
  """
  @spec release(String.t()) :: :ok
  def release(id) do
    case Cache.fetch(@namespace, id) do
      {:ok, entry} ->
        Cache.release(entry)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Remove each partial file that no download is going to continue.

  It gives the number of files that it removed. A file of the last day stays,
  because a play of that episode reads what it holds and asks for the rest.
  """
  # Every path here comes from `directory/0` and from `Path.wildcard/1` of that
  # directory. No name of a request or of a service reaches it.
  @sobelow_skip ["Traversal.FileModule"]
  @spec sweep() :: non_neg_integer()
  def sweep do
    before = DateTime.add(DateTime.utc_now(), -@keep_partial_hours, :hour)

    directory()
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&stale?(&1, before))
    |> Enum.map(&remove/1)
    |> Enum.count(&(&1 == :ok))
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    id = Keyword.fetch!(options, :id)
    GenServer.start_link(__MODULE__, options, name: {:via, Registry, {@registry, id}})
  end

  @impl GenServer
  def init(options) do
    id = Keyword.fetch!(options, :id)

    state = %State{
      id: id,
      uri: Keyword.fetch!(options, :uri),
      path: Path.join(directory(), id),
      watchers: options |> Keyword.get(:watcher) |> List.wrap()
    }

    {:ok, state, {:continue, :read}}
  end

  # `directory/0` builds the only path here, and it reads the data partition of the
  # device. No name of a request reaches it.
  @sobelow_skip ["Traversal.FileModule"]
  @impl GenServer
  def handle_continue(:read, %State{} = state) do
    File.mkdir_p!(directory())
    from = held_bytes(state.path)

    {:noreply, %State{state | written: from, request: request(state, from)}}
  end

  @impl GenServer
  def handle_call({:watch, pid}, _from, %State{} = state) do
    {:reply, {:ok, state.written}, %State{state | watchers: [pid | state.watchers]}}
  end

  @impl GenServer
  def handle_info({:wrote, count}, %State{} = state) do
    written = state.written + count
    tell(state, {:bytes, written})

    {:noreply, announce(%State{state | written: written})}
  end

  # The request truncated the file and began again, because the server ignored the
  # range. The count therefore starts from nothing.
  @impl GenServer
  def handle_info(:restarted, %State{} = state) do
    {:noreply, %State{state | written: 0, told_at: nil}}
  end

  # One process makes one request, so the answer needs no identifier of its own.
  @impl GenServer
  def handle_info({:request, result}, %State{request: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    finish(result, %State{state | request: nil})
  end

  # The process that held the request died before it answered. `spawn_monitor` and
  # not `Task.async`, so this process lives long enough to tell its watchers.
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{request: ref} = state) do
    {:stop, {:shutdown, reason}, fail(%State{state | request: nil}, reason)}
  end

  @impl GenServer
  def handle_info(_message, %State{} = state), do: {:noreply, state}

  defp complete(entry) do
    Cache.used(entry)
    {:ok, %{paths: [Path.join(Cache.directory(), entry.key)], complete?: true}}
  end

  defp start_or_join(id, uri, tries) do
    child = {__MODULE__, id: id, uri: uri, watcher: self()}

    case DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, _pid} ->
        {:ok, paths(id)}

      # Another play of this episode started it, so this caller joins that one.
      {:error, {:already_started, pid}} ->
        join(pid, id, uri, tries)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The download may finish between the answer above and this call, and a small
  # episode over a fast network does exactly that. A process that has gone either
  # left the file in the cache or failed, and one more turn reads which.
  defp join(pid, id, uri, tries) do
    GenServer.call(pid, {:watch, self()})
    {:ok, paths(id)}
  catch
    :exit, _reason -> ensure(id, uri, tries - 1)
  end

  # A download that finishes between the answer of `ensure/2` and the open of the
  # reader moves the file, so the reader gets both names and opens the one that is
  # there. The cache holds the whole file, so it comes first.
  defp paths(id) do
    %{
      paths: [Path.join([Cache.directory(), @namespace, id]), Path.join(directory(), id)],
      complete?: false
    }
  end

  defp held_bytes(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> 0
    end
  end

  defp modes(0), do: [:write, :binary, :raw]
  defp modes(_from), do: [:append, :binary, :raw]

  # Another process holds the request, because `Req.get/1` with `into: fun` answers
  # only when the body ends. That process also owns the file: a `:raw` file holds the
  # process that opened it, and any other one gets `:not_on_controlling_process`.
  # The audio therefore never reaches the mailbox of this process, and the count does.
  #
  # `spawn_monitor` and not `Task.async`: a link would take this process down with a
  # request that fails, and then no watcher would hear why.
  defp request(%State{} = state, from) do
    server = self()
    path = state.path
    uri = state.uri
    options = Application.get_env(:my_hi_fi, __MODULE__, [])

    {_pid, ref} =
      spawn_monitor(fn ->
        send(server, {:request, read(uri, path, from, options, server)})
      end)

    ref
  end

  defp read(uri, path, from, options, server) do
    case :file.open(path, modes(from)) do
      {:ok, device} ->
        try do
          [
            url: uri,
            headers: headers(from),
            into: writer(server, device, from),
            receive_timeout: @timeout,
            retry: false
          ]
          |> Keyword.merge(options)
          |> Req.new()
          |> Req.get()
        after
          :file.close(device)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp headers(0), do: [{"user-agent", @user_agent}]
  defp headers(from), do: [{"user-agent", @user_agent}, {"range", "bytes=#{from}-"}]

  defp writer(server, device, from) do
    # The file goes back to nothing one time and not for each part, so the flag must
    # live outside the function. `:atomics.exchange/3` gives the value that was
    # there, so the first part alone reads a 0.
    restarted = :atomics.new(1, [])

    fn
      {:data, data}, {request, %{status: 206} = response} ->
        write(server, device, data, {request, response})

      # The server ignored the range, so this answer holds the whole file and not the
      # rest of it. What the file holds is therefore of no use.
      {:data, data}, {request, %{status: 200} = response} when from > 0 ->
        if :atomics.exchange(restarted, 1, 1) == 0 do
          {:ok, 0} = :file.position(device, :bof)
          :ok = :file.truncate(device)
          send(server, :restarted)
        end

        write(server, device, data, {request, response})

      {:data, data}, {request, %{status: 200} = response} ->
        write(server, device, data, {request, response})

      # Any other status holds a message and not audio, so nothing writes it.
      {:data, _data}, accumulator ->
        {:halt, accumulator}
    end
  end

  defp write(server, device, data, accumulator) do
    :ok = :file.write(device, data)
    send(server, {:wrote, byte_size(data)})
    {:cont, accumulator}
  end

  defp finish({:ok, %{status: status} = response}, %State{} = state) when status in [200, 206] do
    case expected(response, state) do
      {:short, want, got} ->
        {:stop, {:shutdown, :short}, fail(state, {:short_read, want, got})}

      :whole ->
        store(state)
    end
  end

  defp finish({:ok, %{status: status}}, %State{} = state) do
    {:stop, {:shutdown, status}, fail(state, {:unexpected_status, status})}
  end

  defp finish({:error, reason}, %State{} = state) do
    {:stop, {:shutdown, reason}, fail(state, reason)}
  end

  # The bytes that arrived against the bytes that the answer named. This is the
  # check that matters, and it costs nothing. An md5 of 50 MB would cost about a
  # second of the CPU of this board and no reader would ask for it.
  defp expected(response, %State{written: written}) do
    case total_bytes(response) do
      nil -> :whole
      ^written -> :whole
      want -> {:short, want, written}
    end
  end

  defp total_bytes(response) do
    case Req.Response.get_header(response, "content-range") do
      [value | _rest] -> from_range(value)
      [] -> response |> Req.Response.get_header("content-length") |> from_length()
    end
  end

  defp from_range(value) do
    case Regex.run(~r{/(\d+)$}, value) do
      [_all, total] -> String.to_integer(total)
      nil -> nil
    end
  end

  defp from_length([value | _rest]) do
    case Integer.parse(value) do
      {bytes, ""} -> bytes
      _other -> nil
    end
  end

  defp from_length([]), do: nil

  # The audio weighs more than a picture, because the eviction must take a picture
  # first. A picture is 1.2 MB and the device reads it again by itself. A track is
  # many times that, and a track on the card is what plays when no network answers.
  # See the `:coldest` read of `MyHiFi.Cache.Entry`.
  defp store(%State{} = state) do
    attributes = %{path: state.path, content_type: "audio/mpeg", keep?: true, weight: 1}

    case Cache.put_file(@namespace, state.id, attributes) do
      {:ok, _entry} ->
        Cache.prune()
        Logger.info("Read #{state.written} bytes of #{state.uri}.")
        tell(state, :done)
        publish(state, :held)
        {:stop, :normal, %State{state | done?: true}}

      {:error, reason} ->
        {:stop, {:shutdown, reason}, fail(state, reason)}
    end
  end

  # The file stays where it is. A later play asks for the rest of the bytes, and the
  # sweep of the supervisor removes it if no play ever does.
  defp fail(%State{} = state, reason) do
    Logger.warning("Could not read #{state.uri}: #{inspect(reason)}")
    tell(state, {:error, reason})
    publish(state, :absent)
    state
  end

  defp tell(%State{watchers: watchers}, message) do
    Enum.each(watchers, &send(&1, {:download, message}))
  end

  # **A watcher hears every count, and a page hears one each second.** A watcher is the
  # element that reads the file, and it needs each count to serve the next byte. A page
  # draws a share of a number that a person reads, and 2500 renders for a track of 40 MB
  # would spend the board on a figure that moves too fast to see.
  # `MyHiFi.Event.Player.Progress` holds the same period for the same reason.
  defp announce(%State{} = state) do
    now = System.monotonic_time(:millisecond)

    if is_nil(state.told_at) or now - state.told_at >= @announce_ms do
      publish(state, :reading)
      %State{state | told_at: now}
    else
      state
    end
  end

  defp publish(%State{} = state, audio_state) do
    Event.publish(:source, %Events.AudioChanged{
      item_id: state.id,
      state: audio_state,
      bytes: state.written
    })
  end

  defp stale?(path, before) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, type: :regular}} ->
        DateTime.compare(DateTime.from_unix!(mtime), before) == :lt

      _other ->
        false
    end
  end

  # `sweep/0` gives each path, and it reads them from `Path.wildcard/1` of
  # `directory/0`. No name of a request reaches this.
  @sobelow_skip ["Traversal.FileModule"]
  defp remove(path) do
    Logger.info("Removing the partial download #{Path.basename(path)}.")
    File.rm(path)
  end
end
