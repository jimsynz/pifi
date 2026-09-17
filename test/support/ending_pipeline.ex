defmodule PiFi.Test.EndingPipeline do
  @moduledoc """
  A pipeline that plays nothing and then says that the track ended.

  `PiFi.Player.Pipeline` holds a sink, the sink holds `aplay`, and `aplay` holds
  a sound card. A test of what the player does at the end of a track therefore
  cannot use it, because the host of a build server holds no card.

  This holds no element at all. It sends the two messages of the protocol that
  `PiFi.Player` reads, so the player cannot tell the difference: the audio began,
  and then it ended.

  Use it with `PiFi.Test.EndingPipeline.use_it/0`.
  """

  use Membrane.Pipeline

  @doc "Make this the pipeline of the player for one test."
  @spec use_it() :: :ok
  def use_it do
    Application.put_env(:pifi, :pipeline, __MODULE__)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:pifi, :pipeline) end)
  end

  @impl Membrane.Pipeline
  def handle_init(_ctx, options) do
    # The player is inside `handle_call/3` while this runs, so both messages wait
    # in its queue until it holds the pid of this pipeline.
    send(options.parent, {:pipeline_playing, self()})
    send(options.parent, {:pipeline_finished, self()})

    {[], %{}}
  end
end
