defmodule MyHiFi.Playback do
  @moduledoc """
  What the device plays, and the controls for it.

  Each control is a generic action, in the same way that `MyHiFi.Device` reports
  the machine. An API extension such as `ash_json_api` serves an action and not a
  function, and a policy guards an action and not a function. The internal API and
  the external API then have one shape.

  `MyHiFi.Player` is the process. It holds the pipeline, the count of tries, and
  the monitor, and none of that belongs in an action. `MyHiFi.Playback.Player`
  holds the actions, and each one calls that process.
  """

  use Ash.Domain, otp_app: :my_hi_fi

  resources do
    resource MyHiFi.Playback.Player do
      define :state, action: :state
      define :play, action: :play, args: [:source, :ref]
      define :stop, action: :stop
      define :pause, action: :pause, args: [:paused?]
      define :next, action: :next
      define :previous, action: :previous
      define :skip, action: :skip, args: [:ms]
      define :standby, action: :standby, args: [:entered?]
      define :enable_source, action: :enable_source, args: [:source, :enabled?]
      define :output, action: :output
      define :select_output, action: :select_output, args: [:id]
    end
  end
end
