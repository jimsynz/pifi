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
- Two audio sources: internet radio, with Shoutcast and HLS streams, and podcasts.
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
- Spotify, Plex, and Squeezecast.
- Volume control.
- More than one device.

## 4. Hardware

| Part | Choice | Note |
|---|---|---|
| Board | Raspberry Pi Zero 2 W | 4 cores. 512 MB of RAM, and Linux sees 363.9 MB of it. |
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

### 4.2 SSH and firmware updates

A development firmware gives an IEx prompt over SSH. A production firmware gives
no shell, and a stereo component in a home needs none.

`nerves_ssh` starts a daemon only when it holds an application environment.
`config/target.exs` writes that environment for `MIX_ENV=dev` alone, so a
production build starts no daemon and asks for no key. The same test removes the
`ssh`, the `sftp-ssh`, and the `epmd` services from the mDNS list. A production
device announces `http` on port 80 instead, because the web interface is then the
way to the device.

A firmware without SSH also holds no `ssh_subsystem_fwup`, and that is how a
device takes new firmware today. Two answers follow.

- **Now.** A person writes an SD card. `mix burn` does that.
- **Later.** The device reads the release list of its own repository from time to
  time, and it takes a newer release itself.

The device pulls, and no person pushes. That decides the hard question. A page
that takes a `.fw` file needs an answer about who may use it: section 10 gives the
home network as the only boundary, and that answer suits a station change and not
a replacement of the software. A device that pulls holds no such endpoint at all.
It chooses what it trusts, and a person on the network cannot give it anything.

Three things that a pull needs, and none of them needs the knob:

- **The address of the release list, and a channel.** A device must know which
  releases are for it.
- **A check on what arrives.** `fwup` verifies a signature, and a public key in
  the firmware is the place for it. Without that check a device trusts whatever
  answers the address.
- **A way back from a release that does not start.** The two partitions already
  give that: `fwup` writes to the one that does not run, and `nerves_heart`
  reverts to the other when the new one fails to say that it started.

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
  @type container :: %{ref: ref(), title: String.t(), artwork: String.t() | nil,
                       favourite?: boolean() | nil}
  @type track :: %{ref: ref(), title: String.t(), subtitle: String.t() | nil,
                   artwork: String.t() | nil, duration_ms: pos_integer() | nil,
                   favourite?: boolean() | nil}
  @type entry :: {:container, container()} | {:track, track()}
  @type capability :: :next | :previous | :search | :skip
  @type page :: %{entries: [entry()], cursor: term() | nil}
  @type place :: %{ms: non_neg_integer(), bytes: non_neg_integer() | nil}
  @type field :: %{key: String.t(), title: String.t(), description: String.t() | nil,
                   link: %{href: String.t(), title: String.t()} | nil,
                   type: :text | :password, value: String.t() | nil,
                   write_only?: boolean()}
  @type action :: %{name: String.t(), title: String.t(),
                    description: String.t() | nil, icon: atom()}
  @type playable :: %{uri: String.t(), headers: [{String.t(), String.t()}],
                      transport: :http | :hls | :download,
                      container: :none | :mpeg_ts | :ogg,
                      format: :mp3 | :aac | :flac | :vorbis | :opus | :speex | :unknown,
                      live?: boolean(), position_ms: non_neg_integer(),
                      key: String.t() | nil,
                      position_bytes: non_neg_integer() | nil}

  @callback title() :: String.t()
  @callback icon() :: atom()
  @callback capabilities() :: [capability()]
  @callback root() :: ref()
  @callback browse(ref(), keyword()) :: {:ok, page()} | {:error, term()}
  @callback search(String.t(), keyword()) :: {:ok, page()} | {:error, term()}
  @callback track(ref()) :: {:ok, track()} | {:error, term()}
  @callback resolve(ref()) :: {:ok, playable()} | {:error, term()}
  @callback next(ref()) :: {:ok, ref()} | {:error, term()}
  @callback previous(ref()) :: {:ok, ref()} | {:error, term()}
  @callback favourite(ref(), boolean()) :: :ok | {:error, term()}
  @callback store_position(ref(), place()) :: :ok | {:error, term()}
  @callback finished(ref()) :: :ok | {:error, term()}
  @callback ref_to_string(ref()) :: {:ok, String.t()} | {:error, term()}
  @callback ref_from_string(String.t()) :: {:ok, ref()} | {:error, term()}

  @callback settings() :: [field()]
  @callback put_settings(%{String.t() => String.t()}) ::
              {:ok, String.t()} | {:error, String.t()}
  @callback settings_actions() :: [action()]
  @callback run_settings_action(String.t()) :: {:ok, String.t()} | {:error, String.t()}

  @optional_callbacks settings: 0, put_settings: 1,
                      settings_actions: 0, run_settings_action: 1

  @spec all() :: [module()]
  def all

  @spec enabled() :: [module()]
  def enabled

  @spec enabled?(module()) :: boolean()
  def enabled?(module)

  @spec enable(module(), boolean()) :: :ok
  def enable(module, enabled?)

  @spec enabled_key(module()) :: String.t()
  def enabled_key(module)

  @spec slug(module()) :: String.t()
  def slug(module)

  @spec from_slug(String.t()) :: {:ok, module()} | {:error, :not_a_source}
  def from_slug(name)

  @spec settings(module()) :: [field()]
  def settings(module)

  @spec put_settings(module(), %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, String.t()}
  def put_settings(module, values)

  @spec settings_actions(module()) :: [action()]
  def settings_actions(module)

  @spec run_settings_action(module(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run_settings_action(module, name)
end
```

Notes on the behaviour:

- `duration_ms` is `nil` for a live stream.
- `cursor` gives the next page. A `nil` cursor means the last page.
- `search/2` returns `{:error, :not_supported}` if the source has no search.
- `capabilities/0` names what the source holds, so a user interface knows which
  controls to draw before it asks for anything. A radio stream holds no place, so
  nothing moves through it and a skip control must be dead. The player reads the same
  list, and a skip of a source with no `:skip` therefore reaches no pipeline.
  `MyHiFi.Source.InternetRadio` gives `[:next, :previous, :search]`, and
  `MyHiFi.Source.Podcasts` gives `[:next, :previous, :search, :skip]`.
- The list names what the source holds, and not what one track holds. A source of
  `:skip` can hold a track that a person cannot move inside, and the player refuses
  that skip when it sees the track. A favourite is not in the list, because
  `favourite?` on each entry is the more exact answer.
- `next/1` and `previous/1` give the track beside this one, in the order that a person
  sees in the browse list. Podcasts move through the episodes of the same show, and
  internet radio moves through the favourite stations. A list of stations moves round,
  in the way that the presets of a stereo do. A list of episodes ends, and the last
  one gives `{:error, :no_more}`. That error and `{:error, :not_supported}` are
  different answers, and `capabilities/0` gives the second one in advance.
- `track/1` describes one track. The now playing screen holds a `ref` and nothing
  else, and without this callback it would have to move through the tree again to
  find what it already had.
- `favourite/2` marks one entry, and it removes that mark. A source with no
  favourites returns `{:error, :not_supported}`, in the same way that `search/2`
  does. Each service holds its own idea of this mark: a station list holds a
  column, and another service holds a list of its own. A user interface therefore
  never reads or writes the mark itself.
- `favourite?` is on a track and on a container, and it is `nil` for a source that
  does not mark that kind. A user interface shows the control for `true` and for
  `false` only, so it needs no knowledge of which source it shows, and it draws one
  control for both kinds. Both kinds carry the mark because each service holds it
  on a different thing: internet radio marks a station, which is a track, and
  podcasts subscribe to a show, which is a container. A later source marks an album
  or a playlist.
- `store_position/2` notes where a person stopped inside a track. The player calls
  it when it stops, when it enters standby, and when a track reaches its end. It is
  a notice and not a question, so a source that keeps no position returns `:ok` and
  not an error, and internet radio does nothing with it because a live stream has
  no position. `search/2` and `favourite/2` return `{:error, :not_supported}`
  instead, and the reason for the difference is the user interface: it must know
  whether to draw a search field and a star, and it draws no control for a
  position.
- `finished/1` says that a track reached its end. The player calls it in place of
  `store_position/2` when a track ends by itself, and a source that holds a played
  mark writes it there. The player starts a live stream again when it ends, because
  a person expects the music to come back, so this never reaches a source of live
  streams.
- `position_ms` of a playable is where that stream begins, and it is 0 for one that
  begins at the start. A source that resumes a track sets it to the point that its
  own `headers` ask for, and the player adds it to the time that it counts. A
  progress bar then shows the place in the whole track. A source that asks for no
  bytes gives 0, even when it holds a place: a podcast episode whose feed gives no
  length is one of those.
- The behaviour names `track/1` and no `container/1`. The web page therefore reads
  a track again after a change of its mark, and it writes the confirmed value on a
  container. One page refreshing one star does not earn a callback that every
  source must implement, and reading the list again would ask a service for a whole
  page each time a person marks something.
- `transport`, `container` and `format` decide the pipeline, and they are separate
  because they vary separately. Of the 44 New Zealand HLS stations, 14 give AAC
  with no container and 8 give MP3 inside MPEG-TS. Of the 6 Ogg stations, 3 hold
  Vorbis and 3 hold FLAC, and the service reports the codec `OGG` for every one.
  One field cannot say any of that. See sections 6.3 and 6.4.
- `:download` is the third transport. A podcast episode arrives faster than its own
  audio, so this device writes it to a file and reads that file. `key` names the
  file and `position_bytes` says where to begin in it. See section 6.2.1.
- `store_position/2` takes a place, and a place holds the time and the byte. The byte
  is what makes a resume exact, and section 9 holds the reason.
- `ref_to_string/1` and `ref_from_string/1` name a `ref` and read that name back.
  The player keeps the last station in the settings, and a setting holds a string.
  A source gives `{:error, :cannot_name}` for a `ref` that it does not name: the
  player needs the tracks, and internet radio therefore names a station and no
  container. See section 9 for why the player stores a name and not a term.
- `icon/0` names the icon of the source, and each user interface draws that name
  in its own way. The web interface draws a heroicon, and the device screen draws a
  shape of its own. The interfaces draw `:radio`, `:library`, `:podcast` and `:cloud`
  today, and any other name gives the default icon. A source therefore reaches the
  top row of the web interface without a change there. This callback holds the
  same rule as `title/0`: the source names what it is, and no interface holds a
  list of the sources.
- `settings/0` names the values that a person can change for this source, and
  `put_settings/1` writes them. `settings_actions/0` names the controls that do
  something and change no value, and `run_settings_action/1` runs one. The four are
  optional, so a source that needs no configuration implements none of them. **A
  settings page therefore holds no knowledge of any source.** The countries of the
  station list belong to internet radio, and the key of the Podcast Index belongs
  to podcasts. See section 10.
- A source checks its own values. "Name at least one country" and "the index
  refused that key" are both facts of one service, so `put_settings/1` gives one
  sentence for a person to read, and no page holds that sentence.
- A field with `write_only?` gives no `value`. The page then shows an empty
  control, and the secret of an index never reaches a browser. A person who changes
  such a value writes each part of it again.
- `link` of a field is separate from `description`, because the web interface draws
  an anchor and the device screen can open nothing.
- `all/0` gives every source. A new source joins that list, and each user
  interface then shows it without a change.
- `enabled/0` gives the sources that a person left in use, and `enable/2` puts one
  in use or takes it out of use. The state stays in the settings under
  `enabled_key/1`, such as `source.podcasts.enabled`, and a source that no person
  changed is in use. **A source out of use leaves each user interface, its
  background jobs do nothing, and a restart does not select it again.**
  `MyHiFi.Playback.enable_source/2` is what a user interface calls, because the
  player must also stop the sound of a source that goes out of use.
- `all/0` and `enabled/0` are two lists for two reasons. A settings page must show
  a source that is out of use, so that a person can put it back in use. A name in
  the settings must still name a source that a person took away.
- `slug/1` and `from_slug/1` name a source in an address, and they read that name
  back. The name comes from the module, such as `internet-radio`, so a new source
  needs no registration. `from_slug/1` compares the name of a request with the
  name of each source of `all/0`. It turns no text into an atom.
- A source keeps its own configuration in an Ash resource.

### 5.2 Output behaviour

An output is a module. The module implements `MyHiFi.Output`.

```elixir
defmodule MyHiFi.Output do
  @type device :: %{id: String.t(), title: String.t()}

  @callback devices() :: [device()]
  @callback sink_spec(device_id :: String.t()) :: Membrane.ChildrenSpec.child_definition()

  @spec module() :: module()
  def module
end
```

Version 1 has one module: `MyHiFi.Output.Alsa`. It reads the ALSA card list and
gives a sink. A later version adds a module for hardware that ALSA does not reach.

It lists every card, and not the USB cards alone. Three reasons ask for that. A
USB DAC is what this device plays through. An I2S DAC on the GPIO header is an
ALSA card as well, so it needs no module of its own. The host of a developer holds
a card, and a person can now choose it and hear the audio while they work.

It lists a playback device of a card, and not the card. A card holds none, one, or
several, and `aplay` opens a device. One HD-Audio card of a laptop holds the
devices 3, 7, 8 and 9 for HDMI and holds no device 0, so `plughw:CARD=Generic,DEV=0`
gives `audio open error: No such file or directory`. The `id` of a device is
therefore its ALSA hardware name, such as `hw:CARD=Generic_1,DEV=0`, and
`sink_spec/1` names the `rate48` definition of `/etc/asound.conf` in its place,
which holds the `plug` layer and the card at 48000 Hz. See section 6.2. The title names the card and the
device, such as `HD-Audio Generic, ALC255 Analog`.

It reads `/proc/asound/cards` and `/proc/asound/card*/pcm*p/info`, so it runs no
command and it needs no new binary.

A device of a USB card comes first in the list. `MyHiFi.Player` uses the first
device when the chosen one is absent, so a target with HDMI audio still uses the
DAC.

**A choice and the card in use are two facts.** `MyHiFi.Player.output/0` gives
`selected`, which is the card that a person chose and is nil for a device that no
person has changed, and `in_use`, which is the card that the sound comes out of.
The two are different when a person chose nothing, and when the card that they
chose has left the machine. One private function holds the rule, and both the
pipeline and the report read it, so the two cannot become different answers. The
settings page of section 10 marks `in_use`, and it says "by default" when
`selected` is nil.

`MyHiFi.Output.module/0` gives the output that the firmware uses, and
`MyHiFi.Player` reads it each time that it needs a sink. A test sets `:output` to
give an output of its own, in the same way that it sets `:sources`. A test that
needs a play to fail therefore depends on no hardware: the host of a developer
holds a card, and the host of a build server may hold none.

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
| `MyHiFi.Peripheral.PiTft` | ILI9341 screen and STMPE610 touch controller, both on SPI0 | Yes | `Input.Touched` |
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
| `Player.Started` | `source`, `track`, `artwork_path`, `live?`, `position_ms` |
| `Player.Paused` | `position_ms` |
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
that it cannot draw in time. A skip publishes one as well, as soon as the source
reports the time that it moved, because a person who presses a skip watches the count.

`Player.Started` holds `position_ms`, because a resume of an episode begins in the
middle and the first `Player.Progress` arrives one second later.

`Player.Paused` is not `Player.Stopped`. A stop leaves the device with nothing
selected, and a pause leaves the track in front of the person, so a user interface
keeps the title and draws a play control.

### 5.6 Player

`MyHiFi.Player` is a GenServer. It holds one pipeline at a time. It accepts these
commands:

- `play(source, ref)`
- `stop()`
- `pause(paused?)`
- `next()`
- `previous()`
- `skip(ms)`
- `standby(entered?)`
- `state()`
- `enable_source(source, enabled?)`

`enable_source/2` puts a source in use, or it takes one out of use. The player owns
this command for the same reason that it owns `select_output/1`: the choice is a
setting, and the player must act on it at once. A play of a source out of use gives
`{:error, :source_not_in_use}`, the sound of a source that goes out of use stops,
and the name of its last track leaves the settings, so a restart selects nothing.
See section 5.1.

The player state holds the source, the track, the position, the pause, and the
connexion state. The player publishes an event on each change, and a
`Player.Progress` event one time each second during playback.

**A pause stops the pipeline and it keeps the track selected.** A play then starts the
pipeline at the place that the source holds, which is the resume of section 9, so a
pause needs no mechanism of its own. A live station opens again at the current point
of the stream, because a live stream holds no place.

`state/0` gives `paused?`. A restored track is a paused track, so a boot shows the
station and a play control. See section 9.

A play leaves standby, because a person who asks for music asks the device to be
awake. A standby that a person leaves does not start a track that they paused.

`next()` and `previous()` ask the source, which owns the order. A move is a play of
another track, so it writes the place of the track that played and it keeps the new
track in the settings.

`skip(ms)` takes a signed number of milliseconds. **It keeps the pipeline.** A start of
a pipeline opens the sound card again and holds a silence of about one second, and a
skip is a control that a person presses again and again, so the player calls the
pipeline and `MyHiFi.Player.FileSource` moves the byte that it reads. See section 9.

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

**Vorbis and FLAC come from a program, and not from a library.** Membrane holds no
decoder for either: hex holds no Vorbis package at all, and
`membrane_flac_plugin` is a parser that decodes nothing. The
`membraneframework-precompiled` organisation holds 13 libraries, and neither
`libvorbis` nor `libFLAC` is among them.

`MyHiFi.Player.PortDecoder` therefore writes the bytes to the standard input of a
program and reads the samples from the standard output. `MyHiFi.Output.APlaySink`
already drives `aplay` that way, so the pattern is proven on this board. NBPR
gives each program, and NBPR ships a binary and no header file, which is all that
a port needs. A NIF would need the headers as well.

Each program reads the Ogg container itself, so neither needs a demultiplexer, and
`membrane_ogg_plugin` depayloads Ogg into an Opus stream only.

Both programs write a WAV header before the samples, and that header names the
rate, the channel count and the width of a sample. The element reads it and tells
the pipeline. It reads the length from nothing: a live stream has no length, and
the two programs disagree about what to write there. `oggdec` writes `0x7FFFFFD3`,
and `flac` writes 0 and warns.

One program cannot serve both codecs. `ogg123` names FLAC, Speex, Opus and Vorbis
among its codecs, and it reads a file to find out which one it holds. Reading from
a pipe it cannot go back to the start, so it takes the first module that it tries
and stops with "Error opening" on a FLAC stream.

### 6.2 The elements

| Job | Element | Native code |
|---|---|---|
| Read an HTTP stream | `MyHiFi.Player.HttpSource` | No |
| Decode Ogg Vorbis | `oggdec` through a port | No |
| Decode FLAC | `flac` through a port | No |
| Read an HLS playlist | `MyHiFi.Player.Hls`, then `Membrane.HLS.Source` | No |
| Read the MPEG-TS container | `Membrane.MPEG.TS.Demuxer` | No |
| Remove the ID3 tags of a packed segment | `MyHiFi.Player.PackedAudio` | No |
| Remove the timestamp for MP3 in MPEG-TS | `MyHiFi.Player.MpegAudio` | No |
| Parse AAC | `Membrane.AAC.Parser` | No |
| Decode AAC and HE-AAC | `Membrane.AAC.FDK.Decoder` | libfdk-aac |
| Decode MP3 | `Membrane.MP3.MAD.Decoder` | libmad |
| Send to the DAC | `MyHiFi.Output.Alsa` | No |

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

The player holds no resampler of its own. It tells `aplay` the sample rate that
the decoder gives, and if that rate changes it starts `aplay` again. This removes
the need for ffmpeg.

**ALSA holds the card at 48000 Hz, and that is not a preference.** USB audio sends
one isochronous packet in each 1 ms frame, so 44100 Hz needs 44.1 samples in a
packet and a controller must alternate the size of them. The dwc2 controller of
this board handles that badly: it wrote
`WARNING: drivers/usb/dwc2/hcd.c:2685 dwc2_assign_and_init_hc` while a 44100 Hz
stream played on 2026-08-24, and a person heard noise.

`rate48` of `/etc/asound.conf` therefore holds the card at 48000 Hz and ALSA
converts. `MyHiFi.Output.Alsa.sink_spec/1` names that definition in the place of
`plughw`. The DAC accepts 44100 Hz, so nothing below this layer would have chosen
to convert. See section 17 for the tone that found it.

Almost every podcast holds 44100 Hz MP3, and both RNZ streams hold 24000 Hz, which
is why internet radio never met this and the first podcast did.

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

### 6.2.1 A podcast episode

An episode does not arrive at the bitrate of its audio. A server sends the whole
file at the speed of the network, so the demand of Membrane cannot pace it: that
demand reaches the pad of an element, and it cannot reach a socket that Finch owns.
`MyHiFi.Player.HttpSource` therefore dropped the oldest audio of an episode 1259
times in one read, and a person heard fragments.

`MyHiFi.Player.Download` writes the file, and `MyHiFi.Player.FileSource` reads it at
the speed of the sound card. **A file needs no flow control.** The file is the
buffer, so the element holds no queue of its own: it reads no further than the bytes
that the download reports, and it waits there.

A stop of the playback does not end a download. The request is already in flight, and
a content delivery network often sends the whole file first. A later play of that
episode therefore asks the network for nothing and it begins at once.

### 6.3 HLS

Version 1 plays HLS. `membrane_hls_plugin` v3.0.11 gives `Membrane.HLS.Source`,
which reads a media playlist and gives one buffer for each segment. It adds 13
more Elixir dependencies, and none of them holds native code. Two handle H.264 and
WebVTT, and this firmware uses neither.

HLS matters here. Radio Browser holds 242 New Zealand stations, and 46 of them
(19%) use HLS. Every commercial network uses HLS: Newstalk ZB, ZM, The Edge, The
Rock, The Sound, The Hits, Coast, and George FM. RNZ sends direct MP3 and AAC.

An HLS address gives a playlist and not audio, and the playlist decides the
pipeline. `MyHiFi.Player.Hls` reads it. A count of the 44 addresses on 2026-08-22:

| Shape | Stations | Pipeline |
|---|---|---|
| Master playlist, `.aac` segments | 14 | ID3 removal, AAC parser, fdk-aac |
| Master playlist, `.ts` segments | 17 | MPEG-TS demultiplexer, then AAC or MP3 |
| Media playlist, `.ts` segments | 4 | The same, with no master to read |
| No answer, or another shape | 9 | |

Three facts come out of that count, and each one changes the design.

- **A station address is a master playlist or a media playlist.** 4 stations give
  a media playlist, so the player cannot expect a master.
- **`Membrane.HLS.SourceBin` cannot serve this.** It reads a variant stream as
  MPEG-TS always, and 14 stations hold no container. `Membrane.HLS.Source` takes
  the format as an option, so this firmware reads the playlist itself and gives
  that option.
- **8 stations send MP3 inside MPEG-TS**, with the codec `mp4a.40.34`. HLS is not
  only AAC, so the transport, the container, and the codec are three separate
  facts. See `MyHiFi.Source.playable/0`.

Two elements of this firmware sit between a source and a decoder, and each one
answers a fault that a real station showed.

- `MyHiFi.Player.PackedAudio` removes the ID3v2 tag that section 3.4 of RFC 8216
  puts at the start of each packed audio segment. `Membrane.AAC.Parser` stops with
  `:invalid_adts_header` on that tag.
- `MyHiFi.Player.MpegAudio` removes the timestamp of each buffer for MP3 inside
  MPEG-TS. `membrane_mp3_mad_plugin` holds a fault, and that fault stops the
  decoder at the first frame of every such stream. The module documentation holds
  the detail.

### 6.4 Ogg holds more than one codec

Ogg is a container, and it carries Vorbis, FLAC, Opus or Speex. Radio Browser
reports the codec `OGG` for each one, so the table cannot say which codec a
station sends. Two of the FLAC stations name FLAC in their title and `OGG` in
their codec.

The first page of the stream names it. Each codec writes an identification header
at the start of that page: `\\x01vorbis`, `\\x7FFLAC`, `OpusHead`, or `Speex`.
`MyHiFi.Player.Ogg` reads those bytes and no more, because a live stream never
ends.

A read of the 6 New Zealand Ogg stations on 2026-08-22 gave 3 Vorbis and 2 FLAC,
and one station gave no answer. `container` therefore holds `:ogg` and `format`
holds the codec inside it, in the same way that HLS separates the container from
the codec. See section 5.1.

### 6.5 The Bundlex target problem

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

Domain `MyHiFi.Podcast`:

- `Show` holds one podcast. Attributes: `id`, `feed_url`, `index_id`, `title`,
  `author`, `description`, `artwork_url`, `subscribed?`, `last_fetched_at`,
  `last_error`. `feed_url` is the identity, so the index and a feed read never make
  two rows for one podcast.
- `Episode` holds one recording. Attributes: `id`, `show_id`, `guid`, `title`,
  `subtitle`, `description`, `audio_url`, `mime_type`, `byte_length`,
  `duration_ms`, `published_at`, `artwork_url`, `position_ms`, `position_bytes`,
  `played?`.
  `show_id` with `guid` is the identity, because a `guid` is unique inside its feed
  and not between feeds.
- Actions on `Show`: `read`, `destroy`, `subscriptions`, `upsert_from_feed`,
  `upsert_from_index`, `subscribe`, `unsubscribe`, `record_error`.
- Actions on `Episode`: `read`, `destroy`, `by_show`, `upsert_from_feed`,
  `store_position`, `mark_played`.
- `upsert_from_index` uses `upsert_fields [:index_id]`, so a row that exists takes
  the identifier of the index and nothing else. The publisher owns the title and
  the description, and this is that rule in one line of the DSL.
- SQLite holds the foreign key, so the episodes of a show go before the show.

Domain `MyHiFi.Settings`:

- `Setting` holds one configuration value. It uses a key and a value.
- The settings include the output device, the station countries, and the standby
  state.

Domain `MyHiFi.Playback`:

- `Player` holds no data. It gives one generic action for each control: `state`,
  `play`, `stop`, `standby`, `output`, and `select_output`.
- `MyHiFi.Player` is the process, and it holds the pipeline, the count of tries,
  and the monitor. None of that belongs in an action, so each action calls that
  process. Read the two names with care.
- No page calls the process. Each page calls this domain, so the internal API and
  a later external API have one shape, and a policy can guard each control.
- `play` takes the `ref` of a source as it is, and a `ref` is a term of that
  source. An external API needs the name of a `ref` instead, and
  `MyHiFi.Source.ref_from_string/1` reads one. That step belongs to the API: a
  source names the tracks only, and a user interface must play what it browses.

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
- A job reads the feed of each subscribed show, each six hours. A publisher writes
  an episode and no publisher writes one each hour, so four reads in a day is
  often enough. It reads the subscribed shows only, so a search that a person made
  once costs the device nothing later. See `MyHiFi.Podcast.Show.RefreshAll`.
- The same job removes a show that no person subscribed to and that nothing has
  touched for a week. A search and the trending list write a row for each answer,
  and two visits to the trending list wrote 201 rows on 2026-08-23. Those rows are
  worth keeping for a while and not for ever.
- A device keeps the newest 200 episodes of a show. One feed of the measurement
  holds 2955, and no person moves through that with a knob. A read asks for 200,
  and the job removes what an earlier read left behind when a feed grows.
- A job fetches artwork and writes it to the cache.

`MyHiFi.Podcast.Refresh` holds the read of one feed, and both the job and
`MyHiFi.Source.Podcasts` call it. A person opening a show and a schedule reading a
feed must not disagree about what a feed means.

## 8. Station data

The station list comes from the public Radio Browser service. The device copies
the list into SQLite. Search then works on the local copy, and it works without
the internet.

The person selects the countries in the web interface. The default is New
Zealand. The sync job then copies only those countries.

The New Zealand list is small. The Radio Browser answer is 280 KB of JSON for 242
stations. A country filter therefore keeps the database small.

## 8.1 Podcast data

A podcast needs two services, and they answer different questions.

The **Podcast Index** finds a show. See <https://podcastindex.org>. It gives a
title, an author, artwork, and the address of the feed. It gives no episode.
`MyHiFi.Podcast.Index` reads it.

The **feed of the publisher** gives the episodes. `MyHiFi.Podcast.Feed` reads it
with `MyHiFi.Podcast.Feed.Parser`, one chunk at a time, and it stops when it holds
200 episodes. A feed writes the newest episode first, so those are the newest 200.
Across the 49 feeds of the measurement this reads 44 MB of 149 MB.

The feed decides, and not the index. Three reasons:

- A private feed is never in the index. A Patreon feed or a members feed carries a
  token in its address, and no person can search for it. Such a feed is exactly the
  one that a person names by its address.
- The publisher owns the title, the description and the enclosure.
- A feed holds a new episode before the index reads it.

The index asks each caller for a key and a secret, and it gives both for no money.
Each device holds its own in `MyHiFi.Settings`, so no firmware image holds a
secret and no two devices share a rate limit. A device with no key still plays
every show that a person subscribed to, because `Subscriptions` reads the local
rows.

A person writes the key on the settings page. That page never sends the secret back
to a browser: it says whether the device holds one, and a person who changes it
writes both values again. A save asks the index for its category list, so a person
learns then whether the key works and not when a search fails. A fault of the
network says so, and it does not blame the key.

`X-Auth-Date` of the index holds a window of 3 minutes, so a request before the
first NTP synchronisation fails. `MyHiFi.Podcast.Index` asks `nerves_time` first
and gives `:clock_not_synchronised`, because a 401 names no cause.

The source writes a `Show` for each answer of a search and of the trending list, so
a `ref` is `{:show, id}` in every branch. Opening a show reads its feed when the
local copy is older than one hour. A read that fails keeps the episodes that the
device holds, and `last_error` says why there is nothing newer.

An episode plays over HTTP with no container. 8771 of the 8773 episodes of the
measurement hold `audio/mpeg` and 2 hold `audio/x-m4a`, so MP4 waits for a reason
and an m4a episode names why it cannot play. See section 6.

A resume asks for the bytes from a point with a `range` header, and the point in
time becomes a byte offset through the bitrate. `MyHiFi.Player.Mp3` reads that
bitrate out of the audio itself, from the header of its first frame. It follows
`MyHiFi.Player.Ogg`, which reads the first page of a stream to name the codec.

**The metadata of a feed decides nothing here**, and a measurement of 5 real
episodes on 2026-08-23 says why. The `length` of an enclosure is often not the
length of the file: one of the five named 14,165,913 bytes and sent 7,270,145, and
another named 11,339,285 and sent 14,320,536. A publisher who adds an advertisement
at the time of the request changes the size, and the feed keeps the old number.

| Where the numbers come from | Worst error of the five, seeking to the middle |
|---|---|
| The length and the duration of the feed | 227 s |
| The real length with the duration of the feed | 119 s |
| The bitrate of the audio | **0.03 s** |

All 5 episodes hold one bitrate for the whole file, so one frame header answers the
question. The reader asks for 10 bytes to find the length of the ID3v2 tag, which
holds a picture and is often tens of kilobytes, and then for 4 KB at the start of
the audio. It runs only when a person resumes, and an episode with no place has
never played, so a first play asks for nothing.

A resume that cannot read the bitrate starts at the beginning. That repeats some
audio, and a wrong offset would step over some instead.

### 5.6.1 The end of a stream

`live?` of the playable decides what the player does when a stream ends.

- `live?: true` starts it again. A live stream that ends is a fault of the network,
  and a person expects the music to come back. The player waits two seconds, and it
  gives up after five tries. **A start that a person asks for cancels that wait.** The
  pending start belongs to the stream that failed, and a stale one would build a second
  pipeline beside the one that plays: the second `aplay` finds the sound card busy.
- `live?: false` stops, publishes `Stopped{reason: :finished}`, and calls
  `finished/1` of the source. Nothing starts again, because the track is over.

The player writes the place of a track through `store_position/2` when a person
stops it, when a person pauses it, when the device enters standby, when a fault of the
network ends the audio, when a person chooses another output, and when a person plays
something else. The last one holds a move to the next track as well, so a person who
leaves an episode finds it where they left it. It writes none for a track that
never began, because 0 would lose the place that the person already had. It writes
none at the end of a track either: `finished/1` runs there, and a source that marks
an episode played returns the place to the start itself.

`MyHiFi.Player.Pipeline` holds `aplay`, and `aplay` holds a sound card, so a test
of this cannot use it. `config :my_hi_fi, :pipeline` names another pipeline, in the
same way that `:sources` and `:output` name another source and another output.

## 9. Standby and resume

The device has two states: **active** and **standby**.

In standby the device stops the audio and turns off the screen. It keeps the
network and the web interface active. It also keeps the last position.

When the device leaves standby, it starts the last track again. For a live stream
it opens the station again, because a live stream has no position. For a track
with a length, it starts at the last position. A podcast episode is such a track.
`MyHiFi.Player` calls `store_position/2` on the source when it stops, and when it
enters standby. It gives a place, and a place holds two numbers: the time from the
start, and the byte of the file that the reader had reached.

**The byte is what makes a resume exact.** A byte offset from a time alone needs a
bitrate, and 11 of 46 real episodes hold more than one: such a resume landed as much
as 1994.6 s from the mark. `MyHiFi.Player.FileSource` reports the byte that it read
and `MyHiFi.Player` holds the time, so the two come from one stop and nothing turns
one into the other. See section 17.

`MyHiFi.Source.Podcasts` writes both on the episode, and the next play opens the file
at that byte. See section 5.6.1.

### A skip

`skip(ms)` moves inside a track that plays, forward or backward. It keeps the
pipeline: the player calls it, and `MyHiFi.Player.FileSource` moves the byte that it
reads. Section 5.6 holds the reason.

**A bitrate cannot turn a time into a byte**, so nothing here does that.
`MyHiFi.Player.Mp3Frame` walks the frame headers of the file and adds the length of
each frame in bytes and in time, so a forward skip is one walk and it measures a real
span. A frame holds no pointer to the frame before it, so a backward skip chooses a
byte from the bitrate of the audio at the current point and then walks forward to
measure what it chose. It measures a second time when the first one lands more than a
tenth from the request. **The time that the player then holds is measured, and never
estimated.** `MyHiFi.Player.Skip` holds this.

A skip needs four things, and a track that holds fewer gives `{:error, :cannot_skip}`:
a source with `:skip` in `capabilities/0`, a track with an end, the `:download`
transport, and the format `:mp3`. MP3 is not a restriction in practice: 8771 of the
8773 episodes of the measurement hold `audio/mpeg`, and an ADTS frame needs another
parser. A skip also needs sound, so a paused track gives `{:error, :not_playing}`.

A skip that reaches past the end of what the file holds stops there. A whole file then
ends the stream, and the source marks the track played. A file that still grows waits
for the bytes, which is what the reader already does when the network is slower than
the audio. A skip that reaches past the start of the file stops at the start.

The audio that already left the reader still plays, so a person hears about one and a
half seconds of the old place: the queue of the decoder holds about one second, and
the queue of the port holds half of one. The display moves at once, because the player
holds the count.

A pause and a standby are different states. A pause belongs to a track, and a standby
belongs to the device. A person who paused a track and then pressed standby did not
ask for music, so leaving standby leaves that track paused. A play leaves standby,
because a person who asks for music asks the device to be awake.

On the first boot the device starts with nothing selected. It does not play.

The settings hold the last station and the standby state, so both survive a
restart. A restart selects that station and plays nothing, in the same way that a
first boot does. A stereo that starts to play by itself after a power cut is a
surprise. `state/0` reports such a track as paused, so a person reads its name and a
play control.

The settings hold a string, so a source names its own `ref` with
`ref_to_string/1`. Nothing turns stored bytes back into a term. A changed row
therefore cannot make an atom or run a function, a person can read the value, and
a source that changes the shape of its `ref` can keep the old name working. Only
a source in `MyHiFi.Source.all/0` comes back, so a source that a later version
removes leaves the device with nothing selected.

## 10. Web interface

The web interface uses Phoenix LiveView. Any person on the local network can open
it. There is no sign-in. The home network is the boundary.

The interface draws one dark faceplate, in the way that a stereo component holds
one. `assets/css/app.css` holds the tokens and the surfaces of it.

The faceplate stays on the screen all the time, and it holds two rows:

- **The fascia.** It holds one control for each source, and the settings control at
  the far right. A source gives its own title and its own icon, so a new source
  needs no change here. See section 5.1. The control of the page that a person
  reads holds the accent colour.
- **The display.** It holds the power control at the left, the artwork, the state,
  the title, the second line, the time, and the stop control. The power control
  enters standby, and it leaves standby. See section 9. A stream with no end holds
  a `Live` badge beside the title. That fact comes from `live?` of
  `Player.Started`, which comes from the playable, and not from `duration_ms`: a
  track of a known length holds no duration until the first progress event.

`MyHiFiWeb.PlayerLive` draws the display, and `MyHiFiWeb.Layouts` renders it with
`sticky: true`. One process therefore holds the display for a browser tab, and a
move to another page keeps it. That is why the controls stay on the screen.

A touch on the artwork opens the large view. It fills the screen, and it shows the
artwork, the title, the station, the second line, the time, and the two controls.

Under the faceplate the interface shows one of two pages:

- **Browse.** The address names the source, such as `/browse/internet-radio`, and
  the page then shows the tree of that source. It gives a search field, and it draws
  no such field for a source with no `:search` in `capabilities/0`. It gives a control that marks a
  track as a favourite. The favourites are a container in the tree of the source,
  so they need no page of their own. The entry that plays holds a marker: the page
  follows the `:player` topic, and it compares the `ref` of the track of the player
  with the `ref` of each entry. A station that a start selected plays nothing yet,
  so it holds no marker. See section 9.
- **Settings.** It is a nested menu. `/settings` holds one row for each section,
  and each row says what that section holds. A row opens the section at an address
  of its own, so a person can keep the address of one, and the back control of the
  browser moves out of it.

      /settings                        the menu
      /settings/output                 the sound card
      /settings/sources                the sources, and which ones are in use
      /settings/sources/internet-radio one source
      /settings/network                a report
      /settings/storage                a report

  **Each source holds a page of its own, and the page holds no knowledge of any
  source.** Every source page draws the control that puts the source in use, and
  every source has that control. It then draws one control for each field of
  `settings/0` of that source, and one button for each control of
  `settings_actions/0`. Internet radio gives the station countries and "Ask for the
  stations now". Podcasts give the key and the secret of the index, and "Remove the
  key". A source that needs no configuration shows the first control alone. See
  section 5.1.

  A source out of use leaves the fascia, its background jobs do nothing, and the
  player stops if it plays that source. The list of the sources therefore holds
  every source, and the fascia holds the ones in use.

  **The output section is a single choice, and the whole row is the control.** A
  mark at the left of each row holds the state, in the way that a radio control
  does, and no row holds a button. The row of the card in use holds the accent
  colour and a speaker icon. That row is the one that `in_use` of section 5.2
  names, so a device that no person has changed still marks one card, and the row
  then says "by default". A row that a person chose is dead, because
  `select_output` starts the stream again and a touch on the card that already
  plays asks for nothing. A row that is in use by default stays live, so a person
  can make that card their own choice. A choice that names a card which left the
  machine gets a line of its own, because the player uses the first card instead.

**The accent colour comes from the artwork.** `assets/js/accent.js` is a LiveView
hook. The browser already holds the logo, so the browser reads it: the hook draws
the logo to a canvas, it groups the pixels by hue in OKLCH, and it takes the group
with the most colour. It then clamps the lightness and the chroma, because the
colour must stay readable on a near-black faceplate, and it writes
`--color-accent`. The device decodes no image for this, and it needs no image
library. A logo of one colour only gives no accent, and the interface then keeps
the one that it holds. The logo comes from this device, so the canvas stays
readable. See section 13.

## 11. Device interface (later version)

The device interface draws on a screen. It does not use a browser.

**No renderer is chosen.** Three things decide the choice, and the third one rules
a candidate out most often.

1. It draws text from a font, because each screen shows the name of a track.
2. It draws a colour raster, because the now playing screen shows cover art.
3. It is small enough for this board, and it needs no binary that the Nerves
   system does not hold. Scenic is heavy for a Raspberry Pi Zero 2 W.

A peripheral draws itself. See section 5.3. `MyHiFi.DeviceUi` holds the
navigation state, and it publishes the view events. `MyHiFi.Peripheral.PiTft`
receives those events and renders them. It also publishes the touch
events, because it owns the same SPI bus as the touch controller. Another person
can add an SSD1306 OLED screen without a change to `MyHiFi.DeviceUi`.

`MyHiFi.Peripheral.PiTft` shows two screens:

1. **Browse.** A list of entries, from a `View.ListShown` event. The knob moves
   the selection. A press opens a container or plays a track.
2. **Now playing.** The cover art, the track name, the source name, and a
   progress marker with the times.

Open items for the device interface:

- The renderer is not chosen. See above for what it must do.
- Cover art needs the bytes of a JPEG or a PNG as pixels. Decide whether the
  renderer reads those formats, or whether this firmware decodes them first. A
  decoder for either one is native code, and section 6.1 holds what that costs.
- Cover art also needs a size that suits the screen. A podcast writes artwork of
  3000 by 3000, which is 1.2 MB, and this screen holds 320 by 240. Nothing on the
  device resizes an image today, and `vix` cannot cross-compile, because it loads
  its own NIF while it compiles and a build machine is x86_64.
- The link from a frame to the SPI framebuffer needs a driver.

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

The cache lives on the application data partition, at `/root/cache`. **Any part of
the firmware may use it.** `MyHiFi.Cache` is the domain, and `MyHiFi.Cache.Entry`
holds the data about one thing on the disk. `AshStorage` writes the file, with its
disk service.

A namespace says which part of the firmware holds an entry, and a key says which
thing. The caller chooses what each one means, and each namespace holds a directory
of its own. Two callers may therefore choose one key and hold different things.

1. **Artwork.** `MyHiFi.Artwork` holds `:artwork` and keys by the hash of an address,
   so one address is one file however many records name it. It keeps what a cache
   cannot know: the four types that this device serves, the read of the first bytes
   because a `content-type` header is often wrong, and the 4 MB limit for one
   picture.
2. **Downloads.** `MyHiFi.Player.Download` holds `download` and keys by the
   identifier of an episode. It reads the file as fast as the network allows, and
   `MyHiFi.Player.FileSource` plays it while it grows. An entry holds `keep?` while
   a person is in the middle of the episode, and `finished/1` releases that mark.

   A file waits at `<data>/partial/<episode id>` while it grows, and not in the
   cache. `MyHiFi.Cache.Entry.Changes.Write` names a row that names a file that
   exists, and a file whose size changes would make the accounting of the cache
   wrong. `MyHiFi.Player.Download.sweep/0` removes a partial file that an
   interruption left, because no row names such a file and no eviction can see it.

The limit is the free space of the partition, less a fixed reserve of 1 GB. A share of
the free space would give a reserve that grows for no reason on a card of 14.2 GB, and
one too small to matter on a small card. The reserve protects the database and the room
for a download.

**The entry that a person used least recently goes first.** The file system cannot
answer that question: Nerves mounts ext4 with `relatime`, so `atime` moves only when
it is a day old and an entry that a person used an hour ago would look cold. The time
therefore lives on the row, and the web interface writes it each time that it serves a
picture.

An entry that a caller marks with `keep?` goes never. Without that mark one download
of 60 MB would remove 50 covers, and moving through a list of shows would remove the
episode that a person is in the middle of. A cache of nothing but such entries stays
above its limit and reports that, because the caller that marked them is the one that
can release them.

The old rule stopped at 64 MB, and it removed the file that was written longest ago. It
was chosen when a station logo was 3.7 KB to 46 KB and 247 of them needed 5 MB. A
podcast cover is 1.2 MB and a picture of an episode is 1.8 MB, so the podcast work is
what made both rules wrong.

The web interface serves each logo from this device and never from the station, so
the content security policy holds `'self'` for an image. A page that holds no logo
yet shows a space, and `MyHiFi.Artwork.Worker` reads the logo while the track
plays. The page then shows it without a reload.

Three rules keep the cache safe.

- A name from a request reaches the file system only when it holds 64 hexadecimal
  characters and one known extension. Any other name gives 404.
- The type comes from the answer of the station, and not from the address. A
  station that names `logo.png` and sends a JPEG gets a `.jpg` file.
- The device serves PNG, JPEG, GIF and WEBP. It refuses SVG, because an SVG file
  can hold a script, and this device serves each logo from its own address. Such
  a script would run with the rights of the web interface.

**The buffer of a live stream is not part of the cache.** It is a ring buffer in
memory. See section 6.2. Such a buffer on the SD card would write all the time, and
that shortens the life of the card.

A podcast episode is not a live stream, and that reason does not reach it. It is a
finite file that this device writes one time and then reads, so it goes on the card.
An episode is about 50 MB, and two hours of listening each day is about 115 MB each
day. A person who plays one episode two times writes it one time, because the cache
holds it.

**A file is also the only way that a resume can be exact.** A byte offset from a
time needs a bitrate, and 11 of 46 real episodes hold more than one. See section 17.

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
| ~~RAM~~ | Small, and no longer a risk. Linux sees 363.9 MB of the 512 MB, because the custom system gives 16 MB to the GPU and 16 MB to CMA. Measured again on 2026-08-24, with podcasts, the artwork cache and HLS all in place: 187.8 MB available with an HLS stream in play, and the BEAM held 98.6 MB. | |
| ~~Bundlex target~~ | Solved on 2026-08-21. `mix.exs` sets the four variables, and the arm libraries download. | |
| Precompiled builds | Membrane may change or remove an `aarch64` build. | Pin the versions, as `membrane_mp3_mad_plugin` already does. |
| ~~USB host mode~~ | Solved on 2026-08-21. The custom system holds `dr_mode=host`, the USB host stack, and the USB audio driver. | |
| ~~ICY metadata~~ | Solved on 2026-08-21. `MyHiFi.Player.IcyStream` takes the blocks out, and `MyHiFi.Player.HttpSource` asks for them. Read against real stations. | |
| Latency | The `aplay` port adds a buffer, and the samples in front of the sink add more. | A stop gave silence in 35 to 245 ms on 2026-08-21, after the link to the sink got a limit of eight buffers. See section 6.2. |
| ~~HLS weight~~ | Small. `membrane_hls_plugin` pulls in 13 dependencies, and this firmware uses few of them. They hold 1.2 MB of source and no native code. | |
| Buffer size | A large ring buffer needs much RAM. 202.4 MB is available with HE-AAC in play. | Buffer the compressed bytes, and not the samples. A stream in play adds 3 MB to the BEAM for MP3, and 7 MB for HE-AAC. |
| Knob protocol | The I2C protocol and the detent commands need a design. | Design it with the RP2040 firmware, in a later version. Map it to the hint events. |
| Event rate | A `Player.Progress` event each second, and a slow SPI display, may not agree. | Let a display drop events. Measure the PiTFT refresh time. |
| PiTFT pins | The HAT uses SPI0 and some GPIO pins. | Confirm that the I2C pins stay free. |
| PiTFT parts | The clone may not use an ILI9341 screen and an STMPE610 touch controller. | Confirm the parts before you write the driver. |
| ~~A source that arrives faster than the sound~~ | Answered on 2026-08-24. A local file needs no flow control, so `MyHiFi.Player.Download` writes the episode and `MyHiFi.Player.FileSource` reads it at the speed of the sound card. See section 6.2.1. | Read it on the board. |
| ~~A stop that gives up before its own work ends~~ | Answered on 2026-08-24. The player stops the sound, answers, and takes the pipeline down in `handle_continue/2`. `MyHiFi.Output.APlaySink` closes its `aplay` port and drops each buffer after that. | |
| ~~An address that holds no scheme~~ | Answered on 2026-08-24. `MyHiFi.Artwork.readable?/1` refuses one, and the job cancels instead of failing three times. | |
| ~~The position of an episode~~ | Answered on 2026-08-24. The episode holds `position_bytes` beside `position_ms`, and no bitrate turns one into the other. See section 9. | Measure the skew on the board. It is the latency of the pipeline, which was 35 to 245 ms on 2026-08-21. |
| The life of the SD card | An episode of 50 MB goes on the card now. Two hours of listening each day is about 115 MB each day, and 42 GB in a year. | Section 13 holds the reasoning. Measure the size of a real episode, and watch the free space. |
| A download that no person finishes | An entry holds `keep?` until the episode is played, so an episode that a person abandons holds its file against every eviction. 250 of those fill the cache. | `finished/1` releases the mark for an episode that ends. A reconcile that releases the file of an episode whose row is gone is still to write. |

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
| Does a Membrane HLS plugin exist? | Yes. `membrane_hls_plugin` v3.0.11, from kim-company. With `membrane_mpeg_ts_plugin` it pulls in 13 dependencies, and two of them are H.264 and WebVTT. They hold 1.2 MB of source and no native code. |
| Does Membrane precompile the decoders for `aarch64` Linux? | Yes. `precompiled_mad`, `precompiled_fdk-aac`, `precompiled_portaudio`, and `precompiled_ffmpeg` all hold an arm64 build. |
| Do the archives hold headers? | Yes. Each archive holds `include/` and `lib/`. |
| What glibc do they need? | `GLIBC_2.17` only. Nerves glibc is newer, so they load. |
| What architecture is `rpi0_2`? | `aarch64`, glibc, `aarch64-nerves-linux-gnu`. |
| Does the HLS plugin hold native code? | No. It has no `bundlex.exs` and no `c_src`. |
| Does Nerves set the Bundlex target variables? | No. This breaks the precompiled download. See section 6.4. |
| How large is a podcast picture? | A cover is 1.2 MB and a picture of an episode is 1.8 MB. A station logo is 3.7 KB to 46 KB. Measured on the board on 2026-08-23. |
| How much memory does a feed read need on the board? | 1.7 MB, and 1.7 s, for the newest 200 episodes of an 18 MB feed. A small feed of 29 episodes needs 2.8 MB, and that includes the search of the index. |
| How much memory does the board hold with podcasts in place? | `MemAvailable` 190 MB, and the BEAM held 100 MB. Measured after a search, a subscription and two feed reads. |
| How large is the data partition? | 14.2 GB, with 13.5 GB free. The old cache limit of 64 MB was therefore 0.5% of it. |
| How many New Zealand stations use HLS? | 46 of 242 (19%). All of the commercial networks use it. |
| How large is the New Zealand station list? | 280 KB of JSON. |

A dev firmware ran on the board on 2026-08-21. These measurements come from that
device, with the skeleton in operation and no audio in play. It still held the
stock CMA reservation of 128 MB, so the memory rows are the state before the
change of section 4.1. The last table of this section holds the numbers after that
change.

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

The whole firmware ran on the board on 2026-08-22, with a stream in play. The
`aplay` sink sent the samples to the SA9023 USB DAC.

| Measurement | Idle | MP3 in play | HE-AAC in play |
|---|---|---|---|
| Memory that Linux sees | 363.9 MB | 363.9 MB | 363.9 MB |
| Memory available | 222.6 MB | 219.6 MB | 202.4 MB |
| BEAM memory | 77.0 MB | 80.2 MB | 84.3 MB |
| Process memory | 23.1 MB | 24.1 MB | — |
| Binary memory | 3.1 MB | 4.8 MB | — |
| CPU of the four cores | — | 2.3% | 2.3% |
| Load average over one minute | — | 0.04 | — |

| Measurement | Value |
|---|---|
| Time from a play command to the first sound, MP3 | 1.3 seconds |
| Time from a play command to the first sound, HE-AAC | 3.7 seconds |
| Station table, 247 New Zealand stations | 148 KB |
| Artwork cache | Absent. See section 13. |
| Time from a stop command to silence | 35 to 245 ms |

The numbers change three of the plans above.

- The memory is not tight. 202 MB stays free with the heavier codec in play, and
  the earlier note of 176 MB came from a system with a 128 MB CMA reservation.
  Section 15 keeps the RAM row, because HLS and the artwork cache are still to
  come.
- The CPU is not a risk. One stream needs 2.3% of the four cores, and the decoder
  runs 82 times faster than the sound. A second stream, a screen, and a knob all
  fit.
- HE-AAC needs 17 MB more than MP3, and it waits 2.4 seconds longer for the first
  sound. Neither number changes a decision.

The HE-AAC measurement over HLS is absent, because the device plays no HLS yet.

HLS ran on the board on 2026-08-22, from a firmware that had just started. The
numbers for a plain HTTP stream sit above.

| Measurement | MPEG-TS, MP3 | MPEG-TS, AAC | Packed, AAC |
|---|---|---|---|
| CPU of the four cores | 4.7% | 4.8% | 3.3% |
| BEAM memory | 86.6 MB | 87.6 MB | 89.7 MB |
| Memory available | 206.3 MB | 203.5 MB | 198.9 MB |
| Time from a play command to the first sound | 5.1 s | 6.4 s | 3.4 s |

- HLS needs about twice the CPU of a plain stream, and 4.8% of the four cores is
  still small.
- HLS waits 3 to 6 seconds for the first sound, and a plain stream waits 1.3
  seconds. A player must read a playlist and then a segment before it holds any
  audio, and a segment holds 8 to 10 seconds of sound.
- The 13 dependencies of HLS cost no memory while the device sits idle. A firmware
  that had just started held 75.4 MB in the BEAM with HLS, and 77.0 MB without it.
- One earlier reading gave 15.8% of the CPU for MPEG-TS with AAC. That firmware
  had played 40 stations one after the other, and it was starting a pipeline again
  at that moment. A measurement of a device in this state is not a measurement of
  the codec.

38 of the 40 HLS addresses in the table play. Both of the other two give a
transport error before any playlist arrives, and `curl` from another machine
cannot reach them either.

| Shape | Stations that play |
|---|---|
| Packed audio, AAC | 19 |
| MPEG-TS, AAC | 12 |
| MPEG-TS, MP3 | 7 |
| No answer from the station | 2 |

Ogg ran on the board on 2026-08-22, with the programs from NBPR. `flac` sits at
`/srv/erlang/lib/nbpr_flac-1.5.0/priv/usr/bin/flac`, and `NBPR.Application` puts
that directory on the PATH at each start, so `System.find_executable/1` finds it.

| Measurement | Ogg Vorbis | Ogg FLAC |
|---|---|---|
| CPU of the four cores | 2.1% to 3.4% | 3.4% |
| Programs | `oggdec` 1.4.3 | `flac` 1.5.0 |

All 6 Ogg stations play. Two of them name the same address, so 5 addresses serve
the 6: 3 hold Vorbis and 2 hold FLAC.

A port costs no more CPU than a library. Ogg Vorbis needs about the same as MP3
through libmad, and Ogg FLAC needs a little more.

The two packages add 4.4 MB to the firmware, and it goes from 53.9 MB to 58.3 MB.
`nbpr_flac` brings `nbpr_libogg`, and `nbpr_vorbis_tools` brings `nbpr_libao`,
`nbpr_libcurl` and `nbpr_libvorbis`.

`nerves_system_x86_64` is gone from `mix.exs`, and `:x86_64` is gone from the
target list. That system uses musl, and libvorbis does not build against musl.
`nbpr_vorbis_tools` says so itself with `unsupported_libc: [:musl]`, and `nbpr`
0.3.0 added the option that carries it.

NBPR publishes an artefact for each stock Nerves system, and it publishes none
for `nerves_system_myhifi_rpi0_2`. The cache key of an artefact holds the name
and the version of the system, so `mix nbpr.fetch` on this firmware never finds
one, and it builds each package from source instead. A source build needs a
Buildroot backend, and the CI container holds no `docker` and no `podman`. CI
therefore sets `NBPR_BUILD_BACKEND=shell`, which NBPR documents for a native
build outside the canonical Nerves environment, and `ci.yml` names
`nbpr_source_build: true` to get it. The firmware job installs `bc`, `cpio`,
`rsync` and `wget` for Buildroot, and it removes the Buildroot tree before its
cache saves, because that tree is 1.5 GB and the 6 artefacts are 14 MB. A
measurement in the CI image on 2026-08-22 gave 10 minutes for the 6 packages,
and each later run reads the cache and builds nothing. A new package version, or
a new version of the system, starts one more build.

### The lead that the pipeline holds over the sound, measured on 2026-08-24

A resume opens the file at `position_bytes`, so how far it lands from the place
that a person stopped at is the lead that the pipeline holds over the sound. Each
row is a play of 24 seconds and a stop, and the lead is `position_bytes` as a time
less `position_ms`.

| The pipeline | Lead |
|---|---|
| As it was | 31.0 s |
| With `busy_limits_port` on the `aplay` port | 14.0 s |
| With `auto_demand_size` on the decoder as well | 1.7 s |

**The queue of a port has no limit of its own**, so `Port.command/2` never blocked
and nothing paced the pipeline. **Membrane gives a pad that counts bytes 600,000 of
them** by default, and that is 37.5 seconds of a 128 kbit/s episode. Neither number
showed on a live stream, because the network paced it.

1.7 s is the rest of the pipeline: the queue of the decoder, the queue of the port,
and the buffer of ALSA. A longer play gave 3.8 s, so the lead is small and it is not
a constant.

**A resume therefore steps back before the byte that it holds.** 3.8 s of a
128 kbit/s episode is 61 KB, and `MyHiFi.Player.FileSource` steps back 96 KB, so the
step is larger than any lead that a read has measured. A person hears about two
seconds again, and never loses a word. The margin is in bytes because the lead is
itself a count of bytes, so it needs no bitrate and it holds for a variable bitrate
file.

`MyHiFi.Player.Mp3Frame` also lands that byte on a frame boundary. Without it a
resume opens the file in the middle of a frame and MAD skips bytes until it finds
the next one: a read measured 591 such skips. A read on 2026-08-24 stepped back
98,473 bytes from 3,981,312, which is 169 bytes past the margin and under one frame
of it, and the decoder then reported one skipped byte in the place of 591.

**The count that a page shows still holds the time that a person heard**, so it reads
a second or two ahead of the sound after a resume. A skip holds the same lead: the
reader moves at once, and the audio that already left it plays first. Making the two
agree needs the timeline of the decoder in the place of the clock of the player, and
that is work of its own.

### The sample rate that this board can play, measured on 2026-08-24

A podcast sounded distorted on the board. The file was a valid 128 kbit/s, 44100 Hz
MP3, it played correctly on another machine, and the decoder reported no malformed
frame. A 440 Hz tone straight to `aplay`, with no decoder and no pipeline, found the
reason.

| Device | Rate | Level of the tone | Result |
|---|---|---|---|
| `plughw` | 44100 Hz | 36% of full scale | rough |
| `plughw` | 24000 Hz | 36% | clean |
| `plughw` | 44100 Hz | 3.6% | rough |
| `plughw` | 48000 Hz | 36% | clean |
| `plug`, slave rate 48000 | 44100 Hz | 36% | **clean** |

**The level decides nothing and the rate decides everything.** 24000 Hz and 48000 Hz
each hold a whole number of samples in a millisecond, and 44100 Hz does not. USB
audio sends one isochronous packet in each 1 ms frame, so 44100 Hz needs 44.1
samples in a packet and a controller must alternate the size of them. The dwc2
controller of this board wrote
`WARNING: drivers/usb/dwc2/hcd.c:2685 dwc2_assign_and_init_hc` while such a stream
played.

`rate48` of `/etc/asound.conf` holds the card at 48000 Hz, and the last row is that
definition. See section 6.2.

This is not a fault of the podcast work. It was there for every 44100 Hz stream, and
internet radio never showed it because both RNZ streams hold 24000 Hz.

### The measurements of 2026-08-24

The whole firmware ran on the board on 2026-08-24, with 13 subscribed shows, 2054
episodes and 27 artwork entries on the data partition. The device is idle in the
first column, and the numbers come from `/proc/meminfo` and `:erlang.memory/1`.

| Measurement | Idle | HLS HE-AAC in play |
|---|---|---|
| Memory available | 209.8 MB | 187.8 MB |
| BEAM memory | 88.5 MB | 98.6 MB |
| Process memory | 27.2 MB | 29.2 MB |
| Binary memory | 2.5 MB | 4.5 MB |
| CPU of the four cores | — | 3.0% |

This is the HLS measurement that the table above says is absent. HLS needs 10.1 MB
of the BEAM for one stream, and 3.0% of the four cores. Podcasts and the artwork
cache together cost 11.5 MB of the BEAM at idle, against the 77.0 MB of
2026-08-22. The memory is therefore not a risk, and section 15 no longer holds
that row open.

The artwork cache, with 40 station addresses read and served:

| Measurement | Value |
|---|---|
| Addresses read, and pictures stored | 40 read, 33 stored, 27 entries. Several stations name one address. |
| Time to read 40 logos over the network | 17.9 s |
| `MyHiFi.Cache.fetch/2`, one entry | 6.05 ms |
| `MyHiFi.Cache.touch/1`, one entry | 11.82 ms |
| The same write in plain SQL | 2.21 ms |
| `MyHiFi.Artwork.serve/1`, one entry, in series | 26.06 ms |
| 33 entries served, 8 at a time | 438 ms, and 13.27 ms of wall clock for each |
| Cache entries, and the bytes on disk | 27, and 2.4 MB |
| The cache limit, and the free space | 12.45 GB, of 15.2 GB with 14.4 GB free |
| The 5 migrations against an empty database | 704 ms and 902 ms, in two runs |
| The database with 2054 episodes | 4.6 MB, against 332 KB before the feed reads |

**The write for each read costs 11.8 ms and not the "under a millisecond" that
`docs/cache-plan.md` names.** Plain SQL writes the row in 2.21 ms, so the Ash
action holds 9.6 ms of that. A page of 40 covers therefore needs about 0.5 s of
database work, and it needs that only on a first view, because the route sends a
cache header of one week. The plan keeps its first answer, and it keeps it for the
header and not for the speed of the write.

A refresh of 13 subscribed feeds, and a first read of 12 of them:

| Measurement | Value |
|---|---|
| Time for 13 feeds | 47.4 s, and 3.6 s for each |
| Feeds read, and feeds that failed | 13 and 0 |
| BEAM memory before, at the peak, and after | 111.8 MB, 123.5 MB, 108.6 MB |
| Memory available at its lowest | 146.4 MB |

The peak needs 11.7 MB more than the state before it, and the memory available
never went under 146.4 MB. A refresh is therefore not a risk. The BEAM figures of
this table hold the shell of a person as well, so the idle table above is the one
to compare against.

### The bitrate of a real episode, measured on 2026-08-24

I read the newest episode of 47 feeds of the index, three windows of 256 KB in
each, and then every frame of the whole file of each episode that the windows
disagreed about.

| Measurement | Value |
|---|---|
| Episodes read | 46 of 47 feeds |
| Episodes that hold one bitrate | 33 |
| Episodes that hold more than one, by the windows | 13 |
| Episodes that hold more than one, by every frame | 11 |
| Worst seek error of those 11 | 1994.6 s |
| Seek error of a constant bitrate episode of the same sweep | 0.12 s to 0.48 s |

**11 of 46 episodes hold more than one bitrate.** One episode holds 9 bitrates,
from 32 to 320 kbit/s, and another holds 14, from 8 to 160 kbit/s. The 5 episodes
of the measurement of 2026-08-23 all held one bitrate, and that answer was too
small a sample. A resume of such an episode lands as much as 1994.6 s from the
mark, because `MyHiFi.Player.Mp3` reads the bitrate of the first frame and the
rest of the file holds another one.
