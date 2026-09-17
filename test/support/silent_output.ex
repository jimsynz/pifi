defmodule PiFi.Test.SilentOutput do
  @moduledoc """
  An output that reports one card and gives a sink that nothing builds.

  `PiFi.Output.Alsa` lists every card of the machine, so a test that needs a play to
  succeed needed the machine to hold one. The host of a developer holds a card and the
  host of a build server may hold none, and `PiFi.Output` says that a machine without
  one is normal. Such a test read `PiFi.Event.Player.Failed{reason: :no_output_device}`
  in the place of the track that it asked for, and it failed for the hardware of the
  machine and not for the code.

  **The sink is a name and not a sink, and that is on purpose.**
  `PiFi.Player.start/3` asks the output for a sink before it builds the pipeline, so an
  output that gave no sink would fail there. `PiFi.Test.PlayingPipeline` and
  `PiFi.Test.EndingPipeline` hold no element at all, so they never build the name that
  this gives. A test that builds a real pipeline with this output therefore fails on that
  name, which is what it should do: this output makes no sound.

  `PiFi.Test.NoCardOutput` gives the empty list, for a test that needs a play to fail.
  `PiFi.Test.TwoCardOutput` gives a list of two, for a page that draws a row for each
  card.

  Use it with `PiFi.Test.SilentOutput.use_it/0`, which puts the configuration back at
  the end of the test.
  """

  @behaviour PiFi.Output

  @device %{id: "silent", title: "A card that makes no sound"}

  @impl PiFi.Output
  def devices, do: [@device]

  @impl PiFi.Output
  def sink_spec(_device_id), do: __MODULE__.Sink

  @doc "The card that this output reports."
  @spec device!() :: map()
  def device!, do: @device

  @doc "Make this the output of the firmware for one test."
  @spec use_it() :: :ok
  def use_it do
    Application.put_env(:pifi, :output, __MODULE__)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:pifi, :output) end)
  end
end
