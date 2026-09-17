defmodule PiFi.Player.HttpSource do
  @moduledoc """
  A Membrane source that reads an HTTP audio stream.

  It owns the ring buffer of the player. The buffer keeps the compressed bytes
  and not the samples, so it costs little: a 128 kbps stream is 16 KB each second,
  and 10 seconds cost about 160 KB. The same 10 seconds of samples cost 1.7 MB.
  The buffer stays in memory, and it never touches the SD card.

  It reads with `Req`, and the response arrives as messages. This firmware
  therefore needs one HTTP client and not two. `Membrane.Hackney.Source` would
  bring a second one, and it cannot read the ICY titles that a Shoutcast stream
  sends between the audio.

  A live stream arrives at about the bitrate of the audio, so the buffer stays
  near the low mark and the memory stays small.
  """

  use Membrane.Source

  require Membrane.Logger

  alias PiFi.Player.IcyStream

  def_options(
    uri: [
      spec: String.t(),
      description: "The address of the stream."
    ],
    headers: [
      spec: [{String.t(), String.t()}],
      default: [],
      description: "Extra request headers."
    ],
    buffer_bytes: [
      spec: pos_integer(),
      default: 64 * 1024,
      description: """
      How many bytes to hold before the first sound. It hides a short
      network fault. 64 KB is about 4 seconds of a 128 kbps stream.
      """
    ]
  )

  # `demand_unit: :bytes` is not optional here. Without it a manual output pad
  # takes the default unit, the `handle_demand/5` clause below never matches, and
  # nothing ever leaves this element. The queue then grows until the device runs
  # out of memory and restarts, which is what happened on the first try.
  def_output_pad(:output,
    accepted_format: %Membrane.RemoteStream{},
    flow_control: :manual,
    demand_unit: :bytes
  )

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            uri: String.t(),
            headers: [{String.t(), String.t()}],
            buffer_bytes: pos_integer(),
            response: term() | nil,
            icy: PiFi.Player.IcyStream.t() | nil,
            queue: binary(),
            demand: non_neg_integer(),
            filling?: boolean(),
            done?: boolean()
          }

    defstruct [
      :uri,
      :response,
      :icy,
      headers: [],
      buffer_bytes: 64 * 1024,
      queue: <<>>,
      demand: 0,
      filling?: true,
      done?: false
    ]
  end

  @impl true
  def handle_init(_ctx, options) do
    {[],
     %State{
       uri: options.uri,
       headers: options.headers,
       buffer_bytes: options.buffer_bytes
     }}
  end

  @impl true
  def handle_playing(_ctx, %State{} = state) do
    case start_request(state) do
      {:ok, response} ->
        icy = IcyStream.new(metaint(response))
        Membrane.Logger.info("Reading #{state.uri}, ICY interval #{inspect(icy.metaint)}")

        {[stream_format: {:output, %Membrane.RemoteStream{}}],
         %State{state | response: response, icy: icy}}

      {:error, reason} ->
        raise "Could not read #{state.uri}: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_demand(:output, size, :bytes, _ctx, %State{} = state) do
    serve(%State{state | demand: state.demand + size})
  end

  @impl true
  def handle_info(message, _ctx, %State{response: response} = state) when response != nil do
    case Req.parse_message(response, message) do
      {:ok, parts} -> handle_parts(parts, state)
      :unknown -> {[], state}
    end
  end

  @impl true
  def handle_info(message, _ctx, state) do
    Membrane.Logger.debug("Ignoring #{inspect(message)}")
    {[], state}
  end

  defp handle_parts(parts, state) do
    {state, titles} =
      Enum.reduce(parts, {state, []}, fn
        {:data, data}, {%State{} = acc, titles} ->
          {audio, new_titles, icy} = IcyStream.split(acc.icy, data)
          {%State{acc | queue: acc.queue <> audio, icy: icy}, titles ++ new_titles}

        :done, {%State{} = acc, titles} ->
          {%State{acc | done?: true}, titles}

        _other, {%State{} = acc, titles} ->
          {acc, titles}
      end)

    {actions, state} = state |> trim() |> serve()

    {Enum.map(titles, &{:notify_parent, {:metadata, &1}}) ++ actions, state}
  end

  @doc """
  Drop the oldest audio when the queue grows far past the buffer.

  A live stream arrives at about the bitrate of the audio, so the queue stays near
  the low mark. If it ever grows far past that mark, something downstream has
  stopped asking, and this board has 363.9 MB of memory. Dropping the oldest
  audio keeps the device alive, and a person hears a gap and not a restart.

  This function is public so that a test can reach it. It is the guard that stopped
  a board from running out of memory, and a caller inside this module is the only
  one that needs it.
  """
  @spec trim(State.t()) :: State.t()
  def trim(%State{} = state) do
    limit = state.buffer_bytes * 8

    if byte_size(state.queue) > limit do
      Membrane.Logger.warning(
        "The buffer has #{byte_size(state.queue)} bytes, past the limit of #{limit}. " <>
          "Dropping the oldest audio."
      )

      keep = state.buffer_bytes
      <<_dropped::binary-size(^keep), rest::binary>> = state.queue
      %State{state | queue: rest}
    else
      state
    end
  end

  # Nothing leaves this element until the buffer has enough to hide a short
  # network fault.
  defp serve(%State{filling?: true, done?: false} = state) do
    if byte_size(state.queue) >= state.buffer_bytes do
      Membrane.Logger.info("The buffer has #{byte_size(state.queue)} bytes. Playing.")
      # The sink says when sound starts. This element only says that the buffer
      # has enough to begin.
      serve(%State{state | filling?: false})
    else
      {[], state}
    end
  end

  defp serve(%State{demand: 0} = state), do: {[], state}

  defp serve(%State{queue: <<>>, done?: true} = state) do
    {[end_of_stream: :output], state}
  end

  defp serve(%State{queue: <<>>} = state), do: {[], state}

  defp serve(%State{} = state) do
    size = min(state.demand, byte_size(state.queue))
    <<payload::binary-size(^size), rest::binary>> = state.queue

    actions = [buffer: {:output, %Membrane.Buffer{payload: payload}}]
    state = %State{state | queue: rest, demand: state.demand - size}

    if state.demand > 0 and state.queue == <<>> and state.done? do
      {actions ++ [end_of_stream: :output], state}
    else
      {actions, state}
    end
  end

  defp start_request(%State{} = state) do
    [
      url: state.uri,
      # A Shoutcast server sends the titles only when the request asks for them.
      # See `PiFi.Player.IcyStream`.
      headers: [{"icy-metadata", "1"} | state.headers],
      into: :self,
      receive_timeout: :timer.seconds(15),
      retry: false
    ]
    |> Req.new()
    |> Req.get()
  end

  defp metaint(response) do
    case Req.Response.get_header(response, "icy-metaint") do
      [value | _rest] -> whole_number(value)
      [] -> nil
    end
  end

  defp whole_number(value) do
    case Integer.parse(value) do
      {metaint, _rest} when metaint > 0 -> metaint
      _other -> nil
    end
  end
end
