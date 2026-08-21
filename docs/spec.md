# MyHiFi Specification

- Date: 2026-08-20
- Status: draft
- Licence: Apache-2.0
- Language: this document uses ASD-STE100 Simplified Technical English.

## 1. Purpose

MyHiFi is Nerves firmware for a home audio player. The device connects to a home
stereo. It behaves like a normal stereo component. A person can operate it
without a computer and without a phone.

The device gets audio from a network source. It sends the audio to a digital to
analogue converter (DAC). It shows the state of the music on a small screen. It
also gives a web interface for setup and for control.

## 2. Design goals

- The device starts and plays without help from a computer.
- A person can operate the device with the knob and the screen only.
- The web interface gives the same control as the device screen.
- New audio sources need no change to the player or to the user interface.
- New audio outputs need no change to the player.
- The firmware uses the standard Nerves system. It adds no custom system fork.

## 3. Scope of version 1

Version 1 includes these items:

- Nerves firmware for the Raspberry Pi Zero 2 W.
- One audio source: internet radio, with Shoutcast and HLS streams.
- One audio output: a USB DAC.
- A Membrane pipeline that plays the stream.
- A Phoenix LiveView web interface for setup and for control.
- A Wi-Fi setup mode with an access point.
- A local cache for artwork.
- An in-memory ring buffer for the stream.
- Ash resources for the station list and for the settings.
- Standby mode, with resume of the last station.

Version 1 excludes these items. Later versions add them.

- The PiTFT screen and the on-device user interface.
- The RP2040 knob.
- Spotify, Plex, Squeezecast, and podcasts.
- Volume control.
- More than one device.

## 4. Hardware

| Part | Choice | Note |
|---|---|---|
| Board | Raspberry Pi Zero 2 W | 4 cores. 512 MB of RAM, and Linux sees 301 MB of it. |
| Nerves target | `myhifi_rpi0_2` | A custom system. The stock `rpi0_2` cannot drive a USB DAC. See section 4.1. |
| Audio output | USB DAC on the USB data port | The port must run in host mode |
| Screen | Adafruit PiTFT clone, 2.8 inch, SPI, resistive touch | Later version |
| Knob | SimpleFOC motor, RP2040-Zero controller | Later version |
| Knob link | I2C on the GPIO header | The PiTFT leaves the I2C pins free |
| Storage | SD card, with an application data partition at `/root` | Nerves mounts it. There is no `/data` on this system. |

The board has one USB data port. The USB DAC takes that port. For this reason the
knob does not use USB. The knob uses I2C. This decision changes the RP2040
firmware plan.

### 4.1 The Nerves system

The target is `myhifi_rpi0_2`, and that is a custom system. See
<https://harton.dev/mypihifiguy/nerves_system_myhifi_rpi0_2>. It starts from
`nerves_system_rpi0_2` 2.1.1, and it makes three changes that the stock system
cannot give.

**USB host support.** The stock system holds three USB options: the dwc2
controller, gadget support, and the `g_ether` gadget. It holds no host stack and
no `CONFIG_SND_USB_AUDIO`, so a USB DAC cannot work on it. No stock Nerves system
for a Raspberry Pi holds that option.

**The USB port acts as a host.** The stock `config.txt` leaves `dr_mode` at `otg`,
and the role then comes from the ID pin of the micro-USB socket. A plain adapter
leaves that pin open, so the port acts as a device. The custom system holds
`dtoverlay=dwc2,dr_mode=host`. This ends the network over USB, so a device uses
Wi-Fi, or the serial console on the GPIO header.

**Less memory for graphics.** The stock system gave 192 MB to the GPU and reserved
128 MB of CMA for the VC4 display driver. This device drives no display over HDMI.
The custom system sets `gpu_mem=16`, it removes the VC4 overlay, and it sets CMA
to 16 MB. `MemAvailable` on the board goes from 172 MB to 245 MB. Section 17 holds
the measurements.

A release of the system repository holds the built system, and `mix deps.get`
downloads it. The repository is private, so the download needs a token in
`FORGE_TOKEN`. Without it Nerves tries to build the system, and that takes about
47 minutes.

## 5. Software structure

The software has five parts.

1. **Sources.** A source finds audio and gives a playable stream.
2. **Player.** The player builds and runs a Membrane pipeline. It holds the
   playback state.
3. **Outputs.** An output sends samples to hardware.
4. **Peripherals.** A peripheral owns a piece of hardware. It draws itself, and
   it publishes what the person does.
5. **User interfaces.** The web interface and the device state machine turn
   events into commands.

The parts talk through Phoenix PubSub with typed event structs. A part never
calls another part directly. This keeps each behaviour separate, so a new source,
output, or peripheral needs no change anywhere else.

### 5.1 Source behaviour

A source is a module. The module implements `MyHiFi.Source`. A source shows a
tree of items. A container holds more items. A track plays.

```elixir
defmodule MyHiFi.Source do
  @type ref :: term()
  @type container :: %{ref: ref(), title: String.t(), artwork: String.t() | nil}
  @type track :: %{ref: ref(), title: String.t(), subtitle: String.t() | nil,
                   artwork: String.t() | nil, duration_ms: pos_integer() | nil,
                   favourite?: boolean() | nil}
  @type entry :: {:container, container()} | {:track, track()}
  @type page :: %{entries: [entry()], cursor: term() | nil}
  @type playable :: %{uri: String.t(), headers: [{String.t(), String.t()}],
                      format: :mp3 | :aac | :flac | :ogg | :hls | :unknown,
                      live?: boolean()}

  @callback title() :: String.t()
  @callback root() :: ref()
  @callback browse(ref(), keyword()) :: {:ok, page()} | {:error, term()}
  @callback search(String.t(), keyword()) :: {:ok, page()} | {:error, term()}
  @callback track(ref()) :: {:ok, track()} | {:error, term()}
  @callback resolve(ref()) :: {:ok, playable()} | {:error, term()}
  @callback favourite(ref(), boolean()) :: :ok | {:error, term()}
  @callback ref_to_string(ref()) :: {:ok, String.t()} | {:error, term()}
  @callback ref_from_string(String.t()) :: {:ok, ref()} | {:error, term()}

  @spec all() :: [module()]
  def all
end
```

Notes on the behaviour:

- `duration_ms` is `nil` for a live stream.
- `cursor` gives the next page. A `nil` cursor means the last page.
- `search/2` returns `{:error, :not_supported}` if the source has no search.
- `track/1` describes one track. The now playing screen holds a `ref` and nothing
  else, and without this callback it would have to move through the tree again to
  find what it already had.
- `favourite/2` marks one entry, and it removes that mark. A source with no
  favourites returns `{:error, :not_supported}`, in the same way that `search/2`
  does. Each service holds its own idea of this mark: a station list holds a
  column, and another service holds a list of its own. A user interface therefore
  never reads or writes the mark itself.
- `favourite?` on a track is `nil` for a source with no favourites. A user
  interface shows the control for `true` and for `false` only, so it needs no
  knowledge of which source it shows.
- `ref_to_string/1` and `ref_from_string/1` name a `ref` and read that name back.
  The player keeps the last station in the settings, and a setting holds a string.
  A source gives `{:error, :cannot_name}` for a `ref` that it does not name: the
  player needs the tracks, and internet radio therefore names a station and no
  container. See section 9 for why the player stores a name and not a term.
- `all/0` gives every source. A new source joins that list, and each user
  interface then shows it without a change.
- A source keeps its own configuration in an Ash resource.

### 5.2 Output behaviour

An output is a module. The module implements `MyHiFi.Output`.

```elixir
defmodule MyHiFi.Output do
  @type device :: %{id: String.t(), title: String.t()}

  @callback devices() :: [device()]
  @callback sink_spec(device_id :: String.t()) :: Membrane.ChildrenSpec.child_definition()
end
```

Version 1 has one module: `MyHiFi.Output.UsbDac`. It reads the ALSA card list and
gives a sink. A later version adds `MyHiFi.Output.I2s` for a HAT such as the
PirateAudio.

The Nerves system already holds `alsa-lib`, `aplay`, and `amixer`. The sink sends
raw samples to `aplay` through an Erlang port. This needs no new binary and no
NIF. `amixer` gives hardware volume control, if a later version needs it.

### 5.3 Peripheral behaviour

A peripheral is a process. It owns one piece of hardware. A screen, a knob, and a
touch panel are all peripherals.

```elixir
defmodule MyHiFi.Peripheral do
  @callback init(keyword()) :: {:ok, state :: term()} | {:error, term()}
  @callback subscriptions() :: [MyHiFi.Event.topic()]
  @callback handle_event(MyHiFi.Event.t(), state :: term()) ::
              {:ok, state :: term()} | {:error, term()}
  @callback terminate(reason :: term(), state :: term()) :: :ok
end
```

`MyHiFi.Peripheral.Server` is a GenServer. It wraps a peripheral module. It
subscribes to the topics from `subscriptions/0`, and it calls `handle_event/2`
for each event. A peripheral module therefore holds no PubSub code and no process
code.

A peripheral publishes with `MyHiFi.Event.publish/1`. It calls the function from
its own process. This needs no callback.

A peripheral owns these things:

- The hardware link, such as SPI or I2C.
- The size, the colour model, and the refresh rate of a screen.
- The layout, the fonts, and the scroll window. A peripheral knows how many lines
  fit on its own screen.
- The rate of the events that it publishes.

Version 1 has no peripheral. These come later:

| Module | Hardware | Draws | Publishes |
|---|---|---|---|
| `MyHiFi.Peripheral.PiTft` | ILI9341 screen and STMPE610 touch controller, both on SPI0 | Yes, with Vivid | `Input.Touched` |
| `MyHiFi.Peripheral.Knob` | RP2040-Zero on I2C | No | `Input.Rotated`, `Input.Pressed`, `Input.LongPressed` |
| `MyHiFi.Peripheral.Ssd1306` | 128 by 64 monochrome OLED screen on I2C | Yes, text only | Nothing |

One behaviour, and not two, has a hardware reason. On the PiTFT the screen and the
touch controller share the SPI bus. They use separate chip select lines. One
process therefore owns the bus, and no arbitration is necessary. Two processes on
one bus would need it.

`subscriptions/0` also earns its place. The knob subscribes to the hint topic
only. It must not wake one time each second for a `Player.Progress` event that it
cannot use.

Note: the specification gives the parts of the Adafruit board. Confirm the parts
on your clone before you write the driver.

### 5.4 Device state machine

`MyHiFi.DeviceUi` is a GenServer. It holds the state of the device interface. It
receives the input events, and it publishes the view events and the hints.

It owns these things:

- The current source and the current container.
- The list of entries in that container.
- The index of the selected entry.
- The current screen: browse, or now playing.

It does not own the layout, the fonts, or the scroll window. A peripheral owns
those.

This split has a clear reason. The knob needs a detent count, and the detent
count comes from the length of the list. A peripheral does not know the length,
because a screen shows only the part that fits. `MyHiFi.DeviceUi` knows the
length, so it publishes the `Hint.Detents` event. If a screen owned the
navigation instead, then two screens would give two different detent counts.

The web interface does not use `MyHiFi.DeviceUi`. Each LiveView holds its own
navigation state, because a browser tab is its own session.

### 5.5 Events

`MyHiFi.Event` holds the event structs. Every event is a struct with named
fields. No part sends a bare tuple or a map.

There are four topics: `:player`, `:view`, `:input`, and `:hint`.

Topic `:player`, from `MyHiFi.Player`:

| Event | Fields |
|---|---|
| `Player.Started` | `source`, `track`, `artwork_path` |
| `Player.Stopped` | `reason` |
| `Player.Buffering` | `percent` |
| `Player.Progress` | `position_ms`, `duration_ms` |
| `Player.MetadataChanged` | `title`, `artist`, `artwork_path` |
| `Player.Failed` | `reason` |
| `Player.Standby` | `entered?` |

Topic `:view`, from `MyHiFi.DeviceUi`:

| Event | Fields |
|---|---|
| `View.ListShown` | `title`, `entries`, `selected_index`, `loading?` |
| `View.SelectionMoved` | `selected_index` |
| `View.NowPlayingShown` | none |
| `View.Failed` | `message` |

Topic `:input`, from a peripheral:

| Event | Fields |
|---|---|
| `Input.Rotated` | `delta` |
| `Input.Pressed` | none |
| `Input.LongPressed` | `duration_ms` |
| `Input.Touched` | `x`, `y`, `action` |

Topic `:hint`, from `MyHiFi.DeviceUi`:

| Event | Fields | Effect |
|---|---|---|
| `Hint.Detents` | `count` | The knob sets that many detents. |
| `Hint.Continuous` | none | The knob turns freely, with no detents. |
| `Hint.Endstops` | `at_start?`, `at_end?` | The knob resists at the end of a list. |

A peripheral ignores an event that it cannot use. A screen ignores the hints. A
knob ignores the view events. Nothing reports an error for this, because an
ignored event is normal.

`Player.Progress` arrives one time each second. A slow screen may drop the events
that it cannot draw in time.

### 5.6 Player

`MyHiFi.Player` is a GenServer. It holds one pipeline at a time. It accepts these
commands:

- `play(source, ref)`
- `stop()`
- `standby()`
- `state()`

The player state holds the source, the track, the position, and the connexion
state. The player publishes an event on each change, and a `Player.Progress`
event one time each second during playback.

## 6. Audio pipeline

### 6.1 Where the codecs come from

The `rpi0_2` Nerves system holds no audio decoder. `membrane_alsa_plugin` does
not exist. Compressed audio therefore needs native code on the device.

Membrane solves this. `Membrane.PrecompiledDependencyProvider` gives a URL for a
precompiled library, and it chooses the URL from the build target. The
`membraneframework-precompiled` organisation holds a build for `aarch64` Linux.
`rpi0_2` is `aarch64` with glibc, so the builds match.

`membrane_mp3_mad_plugin` and `membrane_aac_fdk_plugin` both use the provider.
Each precompiled archive holds the header files and the shared library. Bundlex
uses the headers to cross-compile the NIF. The device uses the shared library at
run time.

The libraries are small, and they need only glibc 2.17:

| Library | Size (aarch64) | Needs |
|---|---|---|
| libmad | 70 KB | `libc.so.6`, `GLIBC_2.17` |
| libfdk-aac | 770 KB | `libc.so.6`, `GLIBC_2.17` |

For comparison, the precompiled ffmpeg is 32 MB compressed, and the precompiled
portaudio is 17 MB. The design does not use either one.

### 6.2 The elements

| Job | Element | Native code |
|---|---|---|
| Read an HTTP stream | `MyHiFi.Player.HttpSource` | No |
| Read an HLS playlist | `Membrane.HLS.SourceBin` | No |
| Read the MPEG-TS container | `membrane_mpeg_ts_plugin` | No |
| Parse AAC | `Membrane.AAC.Parser` | No |
| Decode AAC and HE-AAC | `Membrane.AAC.FDK.Decoder` | libfdk-aac |
| Decode MP3 | `Membrane.MP3.MAD.Decoder` | libmad |
| Send to the DAC | `MyHiFi.Output.UsbDac` | No |

The player holds a ring buffer between the source and the decoder. The buffer
holds the compressed bytes, not the samples. Compressed audio is small: a 128
kbps stream is 16 KB each second, so 10 seconds cost about 160 KB. The same 10
seconds of 44.1 kHz 16-bit stereo samples cost 1.7 MB. The buffer therefore sits
before the decoder. It stays in memory, and it never touches the SD card.

The pipeline holds few samples in front of the sink. The sink writes to `aplay`,
and that write blocks while the port is full, so the sink cannot read its own
mailbox while it waits. Membrane allows 400 buffers on an automatic pad, which is
about 20 seconds of samples, and a request to stop then waits behind all of them.
The link to the sink allows eight buffers, which is under half a second. ALSA
holds another half second, and the decoder runs much faster than the sound.

The player does no resampling. It tells `aplay` the sample rate that the decoder
gives. The DAC accepts 44.1 kHz and 48 kHz. If the rate changes, the player
starts `aplay` again. This removes the need for a resampler, and it therefore
removes the need for ffmpeg.

ICY metadata: `MyHiFi.Player.HttpSource` reads the stream with `Req`, so the same
element reads the ICY titles. It sends the `Icy-MetaData: 1` request header, and
`MyHiFi.Player.IcyStream` then takes the blocks out of the bytes.
`Membrane.Hackney.Source` cannot do this, and it would bring a second HTTP client.

A server puts one block into the audio after each `icy-metaint` bytes. The block
starts with one byte that holds the length in units of 16 bytes, and a length of
zero means that the server has nothing new to say. A decoder cannot read those
bytes, so `MyHiFi.Player.IcyStream` removes them. It holds the point that it
reached, because a block can start in one chunk of the network and end in the next
one. It gives each title once, because a server repeats the same title in each
block.

Three answers from real stations on 2026-08-21. A Shoutcast station sends
`icy-metaint` and the titles. RNZ National sends `icy-metaint` and empty blocks
only, so the page shows the station and no track. Some stations send no
`icy-metaint` header, and every byte is then audio.

### 6.3 HLS

Version 1 plays HLS. `membrane_hls_plugin` v3.0.11 gives `Membrane.HLS.Source`
and `Membrane.HLS.SourceBin`. They read a master playlist or a media playlist,
and they follow the updates of a live playlist. The plugin holds no native code.
It adds 10 more Elixir dependencies, and two of them handle H.264 and WebVTT.
This firmware does not use those two.

HLS matters here. Radio Browser holds 242 New Zealand stations, and 46 of them
(19%) use HLS. Every commercial network uses HLS: Newstalk ZB, ZM, The Edge, The
Rock, The Sound, The Hits, Coast, and George FM. RNZ sends direct MP3 and AAC.
The New Zealand HLS streams use AAC and HE-AAC, and fdk-aac decodes both.

### 6.4 The Bundlex target problem

A build on 2026-08-21 proved this problem and the correction.

Bundlex reads the target from four environment variables when `CROSSCOMPILE` is
set: `TARGET_ARCH`, `TARGET_VENDOR`, `TARGET_OS`, and `TARGET_ABI`. Nerves sets
`CROSSCOMPILE` and `REBAR_TARGET_ARCH`. It does not set those four variables.

Each variable then defaults to `"unknown"`. The provider finds no match, and it
returns `nil`. Bundlex then uses `pkg-config` instead, against the Nerves
sysroot, which holds no libmad. The build fails.

The firmware must set these values for `rpi0_2`:

    TARGET_ARCH=aarch64
    TARGET_VENDOR=nerves
    TARGET_OS=linux
    TARGET_ABI=gnu

Bundlex reads the variables when Bundlex itself compiles. The variables must
therefore exist before the dependencies compile. `mix.exs` runs first in every
mix task, so `mix.exs` sets them, from the `@bundlex_targets` map.

Two more problems came with this one.

**`decimal` does not agree.** `membrane_core` needs `ratio`, and `ratio` names
`decimal ~> 1.6 or ~> 2.0`. `ecto_sqlite3` needs `decimal ~> 3.0`. No `ratio`
release accepts version 3, and a lower `ecto_sqlite3` needs a lower `ecto` than
Ash accepts. `mix.exs` therefore overrides `decimal` to `~> 3.0`. That is safe:
`decimal` is optional in `ratio`, and `Ratio.DecimalConversion` reads the `coef`,
`exp` and `sign` fields of the struct and calls no function of the library.
Version 3 keeps those three fields, and each of its breaking changes is in the
context defaults, in `parse`, in `cast`, or in `to_string`.

**Bundlex shares one cache between targets.** It keeps each precompiled library
under `deps/bundlex/priv`, and `_build/<target>/lib/bundlex/priv` is a symbolic
link to that directory. A build for the host leaves an x86 library there, the
release for a target copies it, and the Nerves scrub step then stops with
"Unexpected executable format". The release step `prune_foreign_precompiled/1` in
`mix.exs` removes each library that does not match the architecture of the build.

## 7. Data model

Ash with SQLite holds the data. The database file lives on the application data
partition, at `/root/my_hi_fi.db`.

Domain `MyHiFi.Radio`:

- `Station` holds one internet radio station. Attributes: `id`, `remote_id`,
  `title`, `stream_url`, `codec`, `bitrate`, `hls?`, `country_code`, `language`,
  `tags`, `artwork_url`, `favourite?`, `last_played_at`, `click_count`.
- Actions: `read`, `search` (by title and by tag), `favourites`,
  `upsert_from_remote`, `set_favourite`, `clear_favourite`.

Domain `MyHiFi.Settings`:

- `Setting` holds one configuration value. It uses a key and a value.
- The settings include the output device, the station countries, and the standby
  state.

Domain `MyHiFi.Device`:

- `Network` and `Storage` hold no data. Each one gives one generic action that
  reports what the machine is doing: the interfaces, and the free space of the
  writable partition.
- A generic action carries no benefit over a plain function until something needs
  it. Two things do. An API extension such as `ash_json_api` serves an action and
  not a function, and a policy guards an action and not a function. The internal
  API and the external API then have the same shape.
- `Network` reads VintageNet, which is a target dependency, so the host reports an
  empty list. The implementation module holds that branch, and the resource stays
  a declaration.

Oban does the background work:

- A job copies the Radio Browser station list into `Station`. It reads the
  country list from the settings, and it does one country at a time.
- The job runs after the first boot, and then one time each week.
- A job fetches artwork and writes it to the cache.

## 8. Station data

The station list comes from the public Radio Browser service. The device copies
the list into SQLite. Search then works on the local copy, and it works without
the internet.

The person selects the countries in the web interface. The default is New
Zealand. The sync job then copies only those countries.

The New Zealand list is small. The Radio Browser answer is 280 KB of JSON for 242
stations. A country filter therefore keeps the database small.

## 9. Standby and resume

The device has two states: **active** and **standby**.

In standby the device stops the audio and turns off the screen. It keeps the
network and the web interface active. It also keeps the last position.

When the device leaves standby, it starts the last track again. For a live stream
it opens the station again, because a live stream has no position. For a track
with a length, it starts at the last position. No source gives a track with a
length yet, so the player stores no position and holds no way to move through a
stream.

On the first boot the device starts with nothing selected. It does not play.

The settings hold the last station and the standby state, so both survive a
restart. A restart selects that station and plays nothing, in the same way that a
first boot does. A stereo that starts to play by itself after a power cut is a
surprise.

The settings hold a string, so a source names its own `ref` with
`ref_to_string/1`. Nothing turns stored bytes back into a term. A changed row
therefore cannot make an atom or run a function, a person can read the value, and
a source that changes the shape of its `ref` can keep the old name working. Only
a source in `MyHiFi.Source.all/0` comes back, so a source that a later version
removes leaves the device with nothing selected.

## 10. Web interface

The web interface uses Phoenix LiveView. Any person on the local network can open
it. There is no sign-in. The home network is the boundary.

The web interface has these pages:

- **Now playing.** It shows the artwork, the title, the station, and the state.
  It gives a stop control and a standby control.
- **Browse.** It shows the source list. It then shows the tree of the source. It
  gives a search field, and it hides that field for a source with no search. It
  gives a control that marks a track as a favourite. The favourites are a
  container in the tree of the source, so they need no page of their own.
- **Settings.** It shows the output device, the station countries, the network
  state, and the storage state.

## 11. Device interface (later version)

The device interface draws on a screen. It does not use a browser.

Vivid does the rendering. Vivid is a pure Elixir 2D renderer with no
dependencies. See <https://harton.dev/james/vivid>. Scenic is heavy for this
board, and Vivid is small. Vivid 1.0.0 reads OpenType, TrueType, WOFF, and BDF
fonts. It antialiases, it draws Bezier curves, and it fills shapes with holes.

A peripheral draws itself. See section 5.3. `MyHiFi.DeviceUi` holds the
navigation state, and it publishes the view events. `MyHiFi.Peripheral.PiTft`
receives those events and renders them with Vivid. It also publishes the touch
events, because it owns the same SPI bus as the touch controller. Another person
can add an SSD1306 OLED screen without a change to `MyHiFi.DeviceUi`.

`MyHiFi.Peripheral.PiTft` shows two screens:

1. **Browse.** A list of entries, from a `View.ListShown` event. The knob moves
   the selection. A press opens a container or plays a track.
2. **Now playing.** The cover art, the track name, the source name, and a
   progress marker with the times.

Open items for the device interface:

- Cover art needs a colour raster. Vivid 1.0.0 draws shapes and font glyphs
  only, because `Vivid.Bitmap` holds one bit for each cell and serves the BDF
  fonts. Vivid gets colour raster support upstream. Decide then whether Vivid
  reads JPEG and PNG, or whether this firmware decodes the bytes first.
- The link from a Vivid frame to the SPI framebuffer needs a driver.

If a later version needs a binary or a shared library that the Nerves system
does not hold, then NBPR gives it. NBPR is a Hex repository of Buildroot-built
binaries for Nerves. See <https://github.com/jimsynz/nbpr>. The audio path does
not need NBPR, because Membrane gives the precompiled decoders.

## 12. Knob (later version)

The knob uses a SimpleFOC motor. An RP2040-Zero controls it. The link is I2C.

The Pi is the I2C controller. It reads the knob position and the button state. It
writes the detent pattern to the RP2040. A GPIO interrupt line tells the Pi about
a new event, so the Pi does not poll fast.

`MyHiFi.Peripheral.Knob` implements `MyHiFi.Peripheral`. It publishes
`Input.Rotated`, `Input.Pressed`, and `Input.LongPressed`. It subscribes to the
hint topic only, and it writes each hint to the RP2040.

The detent count comes from `MyHiFi.DeviceUi`, not from a display. A list of 10
items gives 10 detents. The now playing screen gives no detents. Section 5.5
gives the reason.

## 13. Cache and buffer

The cache lives on the application data partition, under `/root`. It holds two
types of data:

1. **Artwork.** The device stores station logos and cover art. It stores them by
   a hash of the source URL.
2. **Downloads.** A later version stores podcast files and Plex files.

The cache has a size limit. The device removes the oldest artwork first. The
device sets the limit from the free space on the partition.

The stream buffer is not part of the cache. It is a ring buffer in memory. See
section 6.2. A buffer on the SD card would write all the time, and that shortens
the life of the card.

## 14. Network

The device uses Wi-Fi. It has no Ethernet port. It also gives a network over the
USB data port, and a workstation uses that during development.

The device has two states: **setup** and **normal**. It is never in both.

In setup the device makes its own access point. The name is `myhifi`, and the
network is open. A person connects to it and opens a web page at `192.168.0.1`. A
wildcard DNS record sends each name to that address, so a telephone opens the page
by itself. The person gives the Wi-Fi name and the password. VintageNetWizard does
this work, and VintageNet keeps the details after a restart.

`MyHiFi.Setup` chooses the state at each start. `VintageNetWizard`
`run_if_unconfigured/1` gives `:configured` for a device that holds Wi-Fi
details, and the firmware then starts the web interface. For a device with no
details it starts the wizard, and the firmware then starts nothing else.

The two states cannot happen together. The wizard serves on port 80, and its
captive portal needs port 80 as well. `MyHiFiWeb.Endpoint` uses the same port.

`MyHiFi.Setup.Monitor` ends setup mode. The wizard runs its `:on_exit` callback
only when a browser asks for the last page of the wizard, and that page is out of
reach in the usual case: the device leaves access point mode as soon as it applies
the network, and the telephone then loses that access point. The monitor watches
the VintageNet configuration of `wlan0` instead. It restarts the device when the
configuration holds a real network and no access point network. The next start
finds the Wi-Fi details and enters normal mode. A restart takes about 12 seconds.

The wizard comes from the `main` branch of the project, at commit `c11eabea849e`,
and not from release 0.4.17. That release is from 2024-06-05, and it needs
plug_cowboy. Each cowlib release from 2.9.0 to 2.19.0 holds two advisories, and
no release fixes them. The `main` branch uses Bandit, which Phoenix already
gives, so cowboy and cowlib stay out of the dependency tree.

## 15. Risks and open items

| Item | Risk | Action |
|---|---|---|
| RAM | Linux sees 301 MB, and not 512 MB. A measurement on 2026-08-21 gave 176 MB free with the skeleton in operation, and the BEAM used 72 MB of the rest. Membrane, the decoders, the ring buffer, and the pages must fit in what is left. | Measure at each step. See #16. A 128 MB CMA reservation holds 91 MB that nothing uses. A change to `config.txt` gives that memory back, and such a change needs a custom Nerves system. |
| ~~Bundlex target~~ | Solved on 2026-08-21. `mix.exs` sets the four variables, and the arm libraries download. | |
| Precompiled builds | Membrane may change or remove an `aarch64` build. | Pin the versions, as `membrane_mp3_mad_plugin` already does. |
| ~~USB host mode~~ | Solved on 2026-08-21. The custom system holds `dr_mode=host`, the USB host stack, and the USB audio driver. | |
| ~~ICY metadata~~ | Solved on 2026-08-21. `MyHiFi.Player.IcyStream` takes the blocks out, and `MyHiFi.Player.HttpSource` asks for them. Read against real stations. | |
| Latency | The `aplay` port adds a buffer, and the samples in front of the sink add more. | A stop gave silence in 35 to 245 ms on 2026-08-21, after the link to the sink got a limit of eight buffers. See section 6.2. |
| HLS weight | `membrane_hls_plugin` pulls in 10 dependencies, and this firmware uses few of them. | Accept it for now. It holds no native code. |
| Buffer size | A large ring buffer needs much RAM, and only about 176 MB is free. | Buffer the compressed bytes, and not the samples. Measure the memory use. |
| Knob protocol | The I2C protocol and the detent commands need a design. | Design it with the RP2040 firmware, in a later version. Map it to the hint events. |
| Event rate | A `Player.Progress` event each second, and a slow SPI display, may not agree. | Let a display drop events. Measure the PiTFT refresh time. |
| PiTFT pins | The HAT uses SPI0 and some GPIO pins. | Confirm that the I2C pins stay free. |
| PiTFT parts | The clone may not use an ILI9341 screen and an STMPE610 touch controller. | Confirm the parts before you write the driver. |

## 16. Order of work

1. Bring up the firmware. Confirm Wi-Fi and the access point wizard.
2. Fix the Bundlex target variables. Confirm that libmad and fdk-aac cross-compile.
3. Detect the USB DAC. Play a test tone through `aplay` from Membrane.
4. Build the Ash resources for `Station` and `Setting`.
5. Copy a country-filtered Radio Browser list with an Oban job.
6. Build the `MyHiFi.Source` behaviour and the internet radio source.
7. Build the player and the pipelines. Play a Shoutcast station and an HLS station.
8. Build the LiveView pages.
9. Add the artwork cache and standby mode.
10. Measure the memory and the CPU. Adjust the plan.

Later versions add the screen, the knob, and more sources.

## 17. Research results

I found these results on 2026-08-20. They support the decisions above.

| Question | Result |
|---|---|
| Does `membrane_alsa_plugin` exist? | No. |
| Does `membrane_portaudio_plugin` exist? | Yes, v0.19.6. PortAudio is not in the Nerves system. |
| What audio software does `nerves_system_rpi0_2` hold? | `alsa-lib`, `aplay`, and `amixer`. Nothing else. |
| Does a Membrane HLS plugin exist? | Yes. `membrane_hls_plugin` v3.0.11, from kim-company. It pulls in 10 dependencies, and two of them are H.264 and WebVTT. |
| Does Membrane precompile the decoders for `aarch64` Linux? | Yes. `precompiled_mad`, `precompiled_fdk-aac`, `precompiled_portaudio`, and `precompiled_ffmpeg` all hold an arm64 build. |
| Do the archives hold headers? | Yes. Each archive holds `include/` and `lib/`. |
| What glibc do they need? | `GLIBC_2.17` only. Nerves glibc is newer, so they load. |
| What architecture is `rpi0_2`? | `aarch64`, glibc, `aarch64-nerves-linux-gnu`. |
| Does the HLS plugin hold native code? | No. It has no `bundlex.exs` and no `c_src`. |
| Does Nerves set the Bundlex target variables? | No. This breaks the precompiled download. See section 6.4. |
| Does Vivid render text? | Yes, from v1.0.0 of 2026-08-14. It reads OpenType, TrueType, WOFF, and BDF fonts. |
| Does Vivid draw a colour image? | No. `Vivid.Bitmap` holds one bit for each cell, and it serves the BDF fonts. |
| How many New Zealand stations use HLS? | 46 of 242 (19%). All of the commercial networks use it. |
| How large is the New Zealand station list? | 280 KB of JSON. |

A dev firmware ran on the board on 2026-08-21. These measurements come from that
device, with the skeleton in operation and no audio in play.

| Measurement | Value |
|---|---|
| RAM that Linux sees | 301 MB of the 512 MB on the board |
| CMA reservation | 128 MB, and 91 MB of it holds nothing |
| Free memory | 176 MB |
| BEAM memory | 72 MB |
| Processes | 717 |
| Schedulers | 4 |
| Restart time to an SSH answer | about 12 seconds |
| Firmware size | 54 MB |
| Time to send new firmware with `mix upload` | 8.7 seconds |

The decoders ran on the board on 2026-08-21. The input was 256 KB from the RNZ
National MP3 stream.

| Measurement | Value |
|---|---|
| MP3 frames decoded | 1364 |
| Audio from those frames | 32.74 seconds |
| Time to decode | 0.398 seconds |
| Speed | 82 times faster than real time |
| One core | 1.2% for one stream |
| Format from the decoder | 24 kHz, 2 channels, s24le |
| Bytes skipped to find the first frame | 384 |
