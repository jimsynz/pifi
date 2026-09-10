defmodule MyHiFi.Output do
  @moduledoc """
  Where the audio goes.

  An output lists the hardware that it can find, and it returns a Membrane sink for
  one piece of that hardware. `MyHiFi.Player` therefore needs no knowledge of any
  particular device.

  `MyHiFi.Output.Alsa` is the only output today, and it lists every sound card that
  ALSA knows about. A later version adds an output for hardware that ALSA does not
  reach.
  """

  @typedoc """
  One piece of output hardware.

  The `id` names the device to `sink_spec/1`. The `title` is for a person to read.
  """
  @type device :: %{id: String.t(), title: String.t()}

  @typedoc "A level that a person chose, where 0 is silent and 100 is the loudest."
  @type percent :: 0..100

  @doc """
  List the output hardware that this module can find.

  It returns an empty list when it finds none, and it does not fail. A machine
  without a sound card is normal, and the host of a developer is one.
  """
  @callback devices() :: [device()]

  @doc """
  Give a Membrane sink that plays to one device.

  The `device_id` comes from the `id` of a device that `devices/0` gave.
  """
  @callback sink_spec(device_id :: String.t()) :: Membrane.ChildrenSpec.child_definition()

  @doc """
  Whether one piece of hardware has a level that this firmware can set.

  **A DAC of a stereo often has none, and that is not a fault.** The PCM5102A of a
  Pirate Audio board gives a fixed output on purpose, so a measurement of it on
  2026-09-09 listed no mixer control at all, and the HiFimeDIY USB DAC of the other
  board listed one. A person with the first one sets the level on their amplifier,
  which is where a stereo has always had it.

  An output that implements neither this nor `c:put_volume/2` gives `false` for every
  device of it.
  """
  @callback volume?(device_id :: String.t()) :: boolean()

  @doc """
  Set the level of one piece of hardware.

  The level is what a person chose, and this module keeps no memory of it.
  `MyHiFi.Output.Volume` owns the number, because the hardware forgets it at each boot
  and a card that arrives later must be told again.
  """
  @callback put_volume(device_id :: String.t(), percent()) :: :ok | {:error, term()}

  @optional_callbacks volume?: 1, put_volume: 2

  @doc """
  Whether the output of this firmware can set the level of one device.

  It returns `false` for an output that names no such callback, so a new output needs no
  obligation to answer a question about hardware that it does not have.
  """
  @spec volume?(String.t()) :: boolean()
  def volume?(device_id) do
    output = module()

    function_exported?(output, :volume?, 1) and output.volume?(device_id)
  end

  @doc """
  Set the level of one device, through the output of this firmware.

  An output that names no `c:put_volume/2` gives `{:error, :no_volume_control}`, which
  is what a caller reads for hardware with a fixed output.
  """
  @spec put_volume(String.t(), percent()) :: :ok | {:error, term()}
  def put_volume(device_id, percent) do
    output = module()

    if function_exported?(output, :put_volume, 2) do
      output.put_volume(device_id, percent)
    else
      {:error, :no_volume_control}
    end
  end

  @doc """
  The output that this firmware uses.

  `MyHiFi.Player` reads this each time that it needs a sink, so a change of the
  configuration needs no restart. A test sets `:output` to give an output of its
  own, in the same way that `MyHiFi.Source.all/0` reads `:sources`.
  """
  @spec module() :: module()
  def module, do: Application.get_env(:my_hi_fi, :output, MyHiFi.Output.Alsa)
end
