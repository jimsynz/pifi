defmodule MyHiFi.Test.NoCardOutput do
  @moduledoc """
  An output that finds no sound card.

  `MyHiFi.Output.Alsa` lists every card of the machine, so the host of a developer
  holds one and the host of the build server may hold none. A test that needs a
  play to fail therefore names this output, and it then depends on no hardware.

  Use it with `MyHiFi.Test.NoCardOutput.use_it/0`, which puts the configuration
  back at the end of the test.
  """

  @behaviour MyHiFi.Output

  @impl MyHiFi.Output
  def devices, do: []

  @impl MyHiFi.Output
  def sink_spec(device_id) do
    raise "MyHiFi.Test.NoCardOutput holds no card, and #{device_id} cannot play."
  end

  @doc "Make this the output of the firmware for one test."
  @spec use_it() :: :ok
  def use_it do
    Application.put_env(:my_hi_fi, :output, __MODULE__)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:my_hi_fi, :output) end)
  end
end
