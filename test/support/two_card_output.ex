defmodule MyHiFi.Test.TwoCardOutput do
  @moduledoc """
  An output that reports two sound cards.

  `MyHiFi.Output.Alsa` lists the cards of the machine, so a host holds a number of
  them that no test can name. A test of the settings page needs a list that it
  knows, because the page draws one row for each card and marks the one in use.

  `MyHiFi.Test.NoCardOutput` gives the opposite answer, for a test that needs a
  play to fail.

  Use it with `MyHiFi.Test.TwoCardOutput.use_it/0`, which puts the configuration
  back at the end of the test.
  """

  @behaviour MyHiFi.Output

  @devices [
    %{id: "rate48:CARD=first,DEV=0", title: "The first card"},
    %{id: "rate48:CARD=second,DEV=0", title: "The second card"}
  ]

  @impl MyHiFi.Output
  def devices, do: @devices

  @impl MyHiFi.Output
  def sink_spec(device_id) do
    raise "MyHiFi.Test.TwoCardOutput makes no sound, and #{device_id} cannot play."
  end

  @doc "The cards that this output reports."
  @spec devices!() :: [map()]
  def devices!, do: @devices

  @doc "Make this the output of the firmware for one test."
  @spec use_it() :: :ok
  def use_it do
    Application.put_env(:my_hi_fi, :output, __MODULE__)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:my_hi_fi, :output) end)
  end
end
