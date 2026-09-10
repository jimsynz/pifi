# MyHiFi

MyHiFi is Nerves firmware for a home audio player.

The device connects to a home stereo. It behaves like a normal stereo component.
A person can operate it without a computer and without a phone.

The device gets audio from a network source. It sends the audio to a USB digital
to analogue converter (DAC). It serves a Phoenix LiveView web interface for setup
and for control. A later version adds a 2.8 inch PiTFT screen and a knob with
dynamic detents.

## State

The firmware plays internet radio and podcasts. It serves a web interface to browse,
to search and to control what plays. The device screen and the knob are not built
yet.

The code is the specification. Each module says what it does and why, and
`MyHiFi.Source`, `MyHiFi.Output` and `MyHiFi.Peripheral` name the rules that a new
source, a new output and a new piece of hardware follow.

## Design

| Item | Choice |
|---|---|
| Board | Raspberry Pi Zero 2 W, with a custom Nerves system (`myhifi_rpi0_2`) |
| Audio output | USB DAC, through `aplay` |
| Audio pipeline | Membrane, with precompiled libmad and fdk-aac decoders |
| Stream types | Shoutcast and HLS |
| Extra binaries, if needed later | [NBPR](https://github.com/jimsynz/nbpr) |
| Data | Ash with SQLite, on the application data partition at `/root` |
| Background work | Oban |
| Web interface | Phoenix LiveView |
| Device screen | A renderer behind a `MyHiFi.Peripheral` behaviour, in a later version. Not chosen yet. |
| Knob | SimpleFOC motor, RP2040-Zero, I2C link, also a `MyHiFi.Peripheral`, in a later version |

Sources, outputs and peripherals are behaviours. A peripheral owns one piece of
hardware: it receives typed events about the player and the navigation state, it
owns its layout, fonts, and scroll window, and it publishes what the person does.
A screen, a knob and a touch panel share that one behaviour. A person can add a
music service, a different DAC, an SSD1306 OLED screen, or another control
without a change to the rest of the firmware.

The first audio source is internet radio. The station list comes from the public
Radio Browser service. Later sources include Spotify, Plex, Squeezecast, and
podcasts. A source implements the `MyHiFi.Source` behaviour, so a new source
needs no change to the player or to the user interface.

## Targets

Nerves applications produce images for hardware targets based on the
`MIX_TARGET` environment variable. If `MIX_TARGET` is unset, `mix` builds an
image that runs on the host (e.g., your laptop). This is useful for executing
logic tests, running utilities, and debugging. Other targets are represented by
a short name like `rpi0_2` that maps to a Nerves system image for that platform.
All of this logic is in the generated `mix.exs` and may be customized. For more
information about targets see:

https://nerves.hexdocs.pm/supported-targets.html

## Getting started

Build for the host, and run the tests:

    mix deps.get
    mix setup
    mix check

Build the firmware:

    export MIX_TARGET=rpi0_2
    mix deps.get
    mix firmware
    mix burn

## Learn more

  * Official docs: https://nerves.hexdocs.pm/getting-started.html
  * Official website: https://nerves-project.org/
  * Forum: https://elixirforum.com/c/nerves-forum
  * Elixir Discord #nerves channel: https://discord.gg/elixir
  * Source: https://github.com/nerves-project/nerves

## Licence

Apache-2.0. See [LICENSE](LICENSE).
