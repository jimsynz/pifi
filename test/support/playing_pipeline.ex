defmodule PiFi.Test.PlayingPipeline do
  @moduledoc """
  A pipeline that says that the audio began, and then keeps playing.

  `PiFi.Player.Pipeline` holds a sink, the sink holds `aplay`, and `aplay` holds a
  sound card, so a test of the controls of the player cannot use it. This holds no
  element at all, and it sends the messages of the protocol that `PiFi.Player`
  reads.

  `PiFi.Test.EndingPipeline` ends the track at once. This one does not, so a test
  can pause it, move inside it, and stop it.

  A skip answers in the way that `PiFi.Player.FileSource` does: it reports the place
  that it reached. It reports the time that the caller asked for, and `moves/1` gives
  it another answer, because a real skip reports the time that it measured and not the
  time of the request.

  Use it with `PiFi.Test.PlayingPipeline.use_it/0`.
  """

  use Membrane.Pipeline

  @doc "Make this the pipeline of the player for one test."
  @spec use_it() :: :ok
  def use_it do
    Application.put_env(:pifi, :pipeline, __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:pifi, :pipeline)
      Application.delete_env(:pifi, :playing_pipeline_moves)
      Application.delete_env(:pifi, :playing_pipeline_fails)
    end)
  end

  @doc """
  Make each pipeline stop as soon as it starts, in the way that a lost stream does.

  The player then holds a pipeline that died, and it starts the stream again after a
  short wait. `fails(false)` gives a pipeline that plays.
  """
  @spec fails(boolean()) :: :ok
  def fails(fails?), do: Application.put_env(:pifi, :playing_pipeline_fails, fails?)

  @doc "The time that the next skip reports, whatever the caller asks for."
  @spec moves(integer()) :: :ok
  def moves(ms), do: Application.put_env(:pifi, :playing_pipeline_moves, ms)

  @impl Membrane.Pipeline
  def handle_init(_ctx, options) do
    if Application.get_env(:pifi, :playing_pipeline_fails, false) do
      # A pipeline that dies inside `handle_init/2` never starts at all, and the player
      # then reads a start that failed. A lost stream is not that: the pipeline plays,
      # and it dies after. This one therefore dies from its own message.
      Process.send_after(self(), :die, 50)

      {[], %{parent: options.parent, byte: 0}}
    else
      # The player is inside `handle_call/3` while this runs, so this message waits in
      # its queue until it holds the pid of this pipeline.
      send(options.parent, {:pipeline_playing, self()})

      {[], %{parent: options.parent, byte: 0}}
    end
  end

  @impl Membrane.Pipeline
  def handle_info(:die, _ctx, state) do
    {[terminate: :normal], state}
  end

  @impl Membrane.Pipeline
  def handle_call(:silence, _ctx, state) do
    {[reply: :ok], state}
  end

  @impl Membrane.Pipeline
  def handle_call({:skip, ms}, _ctx, state) do
    moved = Application.get_env(:pifi, :playing_pipeline_moves, ms)
    byte = state.byte + moved

    send(state.parent, {:pipeline_skipped, self(), %{byte: byte, ms: moved}})

    {[reply: :ok], %{state | byte: byte}}
  end
end
