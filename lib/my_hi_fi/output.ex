defmodule MyHiFi.Output do
  @moduledoc """
  Where the audio goes.

  An output lists the hardware that it can find, and it gives a Membrane sink for
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

  @doc """
  List the output hardware that this module can find.

  It gives an empty list when it finds none, and it does not fail. A machine
  without a sound card is normal, and the host of a developer is one.
  """
  @callback devices() :: [device()]

  @doc """
  Give a Membrane sink that plays to one device.

  The `device_id` comes from the `id` of a device that `devices/0` gave.
  """
  @callback sink_spec(device_id :: String.t()) :: Membrane.ChildrenSpec.child_definition()

  @doc """
  The output that this firmware uses.

  `MyHiFi.Player` reads this each time that it needs a sink, so a change of the
  configuration needs no restart. A test sets `:output` to give an output of its
  own, in the same way that `MyHiFi.Source.all/0` reads `:sources`.
  """
  @spec module() :: module()
  def module, do: Application.get_env(:my_hi_fi, :output, MyHiFi.Output.Alsa)
end
