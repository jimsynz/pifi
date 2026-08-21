defmodule MyHiFi.Playback.Player do
  @moduledoc """
  The controls of the player.

  This resource holds no data, so it needs no data layer. Each action calls
  `MyHiFi.Player`, and that process holds the pipeline and the state.

  Read the name with care. `MyHiFi.Player` is the process, and this module is the
  resource in front of it.

  `play` takes the `ref` of a source as it is, and a `ref` is a term of that
  source. An external API needs the name of a `ref` instead, and
  `MyHiFi.Source.ref_from_string/1` reads one. That step belongs to the API and not
  to this resource: a source names the tracks only, and a user interface must play
  what it browses.
  """

  use Ash.Resource, otp_app: :my_hi_fi, domain: MyHiFi.Playback

  # A generic action does not cast what it returns. These fields therefore describe
  # the shape for a reader and for an API extension, and they enforce nothing.
  @state_fields [
    source: [type: :atom, allow_nil?: true],
    track: [type: :map, allow_nil?: true],
    stream_title: [type: :string, allow_nil?: true],
    artwork_path: [type: :string, allow_nil?: true],
    playing?: [type: :boolean, allow_nil?: false],
    standby?: [type: :boolean, allow_nil?: false],
    position_ms: [type: :integer, allow_nil?: false]
  ]

  actions do
    default_accept []

    action :state, :map do
      description "What the player is doing."

      constraints fields: @state_fields

      run fn _input, _context -> {:ok, MyHiFi.Player.state()} end
    end

    action :play, :atom do
      description """
      Play one track of one source.

      The `ref` comes from `browse/2` or from `search/2` of that source.
      """

      argument :source, :atom, allow_nil?: false
      argument :ref, :term, allow_nil?: false

      run fn input, _context ->
        case MyHiFi.Player.play(input.arguments.source, input.arguments.ref) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :stop, :atom do
      description "Stop the music."

      run fn _input, _context -> {:ok, MyHiFi.Player.stop()} end
    end

    action :standby, :atom do
      description """
      Enter standby, or leave it.

      In standby the device plays nothing and keeps the network. On leaving standby
      it plays the station that it played before.
      """

      argument :entered?, :boolean, allow_nil?: false

      run fn input, _context ->
        case MyHiFi.Player.standby(input.arguments.entered?) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :output, :map do
      description "The output devices, and the one that the player uses."

      constraints fields: [
                    devices: [type: {:array, :map}, allow_nil?: false],
                    selected: [type: :string, allow_nil?: true]
                  ]

      run fn _input, _context -> {:ok, MyHiFi.Player.output()} end
    end

    action :select_output, :atom do
      description """
      Choose an output device.

      The choice stays after a restart, and the player starts the stream again, so
      a person hears the change at once.
      """

      argument :id, :string, allow_nil?: false

      run fn input, _context ->
        case MyHiFi.Player.select_output(input.arguments.id) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end
end
