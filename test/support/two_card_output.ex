defmodule PiFi.Test.TwoCardOutput do
  @moduledoc """
  An output that reports two sound cards.

  `PiFi.Output.Alsa` lists the cards of the machine, so a host holds a number of
  them that no test can name. A test of the settings page needs a list that it
  knows, because the page draws one row for each card and marks the one in use.

  `PiFi.Test.NoCardOutput` gives the opposite answer, for a test that needs a
  play to fail.

  Use it with `PiFi.Test.TwoCardOutput.use_it/0`, which puts the configuration
  back at the end of the test.
  """

  @behaviour PiFi.Output

  @devices [
    %{id: "rate48:CARD=first,DEV=0", title: "The first card"},
    %{id: "rate48:CARD=second,DEV=0", title: "The second card"}
  ]

  @impl PiFi.Output
  def devices, do: @devices

  @impl PiFi.Output
  def sink_spec(device_id) do
    raise "PiFi.Test.TwoCardOutput makes no sound, and #{device_id} cannot play."
  end

  @doc """
  The first card holds a level and the second holds none.

  **A DAC of a fixed output is normal**, and the PCM5102A of a Pirate Audio board is
  one, so a test of the volume needs both answers. See `PiFi.Output.Volume`.
  """
  @impl PiFi.Output
  def volume?(device_id), do: device_id == "rate48:CARD=first,DEV=0"

  @doc """
  Note the level that a caller wrote.

  A card that holds no level refuses one, in the way that `amixer` gives a status
  other than 0 for a control that is not there.
  """
  @impl PiFi.Output
  def put_volume(device_id, percent) do
    if volume?(device_id) do
      note(device_id, percent)
    else
      {:error, :no_volume_control}
    end
  end

  @doc """
  Read the level writes that this output took, newest last.

  A test asks for these rather than reading the hardware, because there is none.
  """
  @spec writes() :: [{String.t(), 0..100}]
  def writes do
    Enum.reverse(:persistent_term.get({__MODULE__, :writes}, []))
  end

  # `:persistent_term` and not a message, because the process that writes the level is
  # `PiFi.Output.Volume` and not the process of the test.
  defp note(device_id, percent) do
    :persistent_term.put(
      {__MODULE__, :writes},
      [{device_id, percent} | :persistent_term.get({__MODULE__, :writes}, [])]
    )
  end

  @doc "The cards that this output reports."
  @spec devices!() :: [map()]
  def devices!, do: @devices

  @doc "Make this the output of the firmware for one test."
  @spec use_it() :: :ok
  def use_it do
    :persistent_term.erase({__MODULE__, :writes})
    Application.put_env(:pifi, :output, __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:pifi, :output)
      :persistent_term.erase({__MODULE__, :writes})
    end)
  end
end
