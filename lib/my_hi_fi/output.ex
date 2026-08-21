defmodule MyHiFi.Output do
  @moduledoc """
  Where the audio goes.

  An output lists the hardware that it can find, and it gives a Membrane sink for
  one piece of that hardware. `MyHiFi.Player` therefore needs no knowledge of any
  particular device.

  `MyHiFi.Output.UsbDac` is the only output today. A later version adds an output
  for an I2S DAC on the GPIO header, such as the PirateAudio.
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
end
