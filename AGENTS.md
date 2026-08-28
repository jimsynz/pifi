# MyHiFi

MyHiFi is Nerves firmware for a home audio player. It connects to a home stereo
and behaves like a normal stereo component. The code is the specification: read
the moduledoc of the part that you change before you make a design decision.

Licence: Apache-2.0.

## What you must know

- **Target board.** Raspberry Pi Zero 2 W, Nerves target `myhifi_rpi0_2`. That
  target is a custom system, not the stock `rpi0_2`. See
  <https://harton.dev/mypihifiguy/nerves_system_myhifi_rpi0_2>. The stock system
  holds no USB host stack and no USB audio driver, so a USB DAC cannot work on
  it, and it reserves 320 MB of the 512 MB for graphics. The board has 4
  cores and one USB data port. It holds 512 MB of RAM, and Linux sees 363.9 MB of
  it, because the custom system gives 16 MB to the GPU and 16 MB to CMA. A
  measurement on 2026-08-22 gave 202.4 MB available with HE-AAC in play, and the
  BEAM held 84.3 MB. One stream needs 2.3% of the four cores. The memory and the
  CPU are therefore not tight, and HLS and the artwork cache are still to come.
- **The USB port holds the DAC.** For this reason the knob uses I2C, not USB.
- **The card plays at 48000 Hz, and 44100 Hz is rough.** USB audio sends one
  isochronous packet in each 1 ms frame, so 44100 Hz needs 44.1 samples in a packet
  and a controller must alternate the size of them. The dwc2 controller of this board
  handles that badly. A 440 Hz tone straight to `aplay` on 2026-08-24 was rough at
  44100 Hz at two levels, and clean at 24000 Hz and at 48000 Hz. `rate48` of
  `rootfs_overlay/etc/asound.conf` therefore holds the card at 48000 Hz, and
  `MyHiFi.Output.Alsa.sink_spec/1` names it in the place of `plughw`. **Do not tell
  `aplay` to open the card at the rate of the decoder.** The DAC accepts 44100 Hz, so
  nothing below that layer will choose to convert. Almost every podcast holds 44100
  Hz MP3, and both RNZ streams hold 24000 Hz, which is why radio never showed this.
- **The Nerves system holds no audio decoder.** It holds `alsa-lib`, `aplay`, and
  `amixer` only. `membrane_alsa_plugin` does not exist. The output sink sends raw
  samples to `aplay` through an Erlang port.
- **The decoders come from Membrane, precompiled.**
  `Membrane.PrecompiledDependencyProvider` gives an `aarch64` Linux build of
  libmad and of fdk-aac. Each archive holds the headers and the shared library,
  so Bundlex cross-compiles the NIF and the device gets the library. Do not add
  ffmpeg or portaudio: they cost 32 MB and 17 MB, and this firmware needs
  neither.
- **Nerves does not set the Bundlex target variables.** Bundlex needs
  `TARGET_ARCH`, `TARGET_VENDOR`, `TARGET_OS`, and `TARGET_ABI`. Nerves sets only
  `CROSSCOMPILE` and `REBAR_TARGET_ARCH`. `mix.exs` sets the four from the
  `@bundlex_targets` map, and a new target needs an entry there.
- **Bundlex shares one precompiled cache between targets.** It keeps each library
  under `deps/bundlex/priv`, and `_build/<target>/lib/bundlex/priv` is a symbolic
  link to it. A host build therefore leaves an x86 library where a target release
  copies it, and the Nerves scrub step stops. The release step
  `prune_foreign_precompiled/1` in `mix.exs` removes what does not match.
- **`decimal` is overridden to `~> 3.0`, and the override must stay.**
  `membrane_core` needs `ratio`, and `ratio` names an old `decimal`.
  `ecto_sqlite3` needs version 3. See section 6.4 of the specification for why
  the override is safe.
- **HLS is in scope for version 1**, and the playlist decides the pipeline, not
  the station record. `MyHiFi.Player.Hls` reads the playlist and gives three
  facts: the transport, the container, and the codec. Four traps, and each one
  cost a build to find.
  - **Do not use `Membrane.HLS.SourceBin`.** It reads a variant stream as MPEG-TS
    always, and 14 of the 44 New Zealand stations hold no container.
    `Membrane.HLS.Source` takes the format as an option, so read the playlist and
    give it.
  - **A station address is a master playlist or a media playlist.** 4 stations
    give a media playlist, so do not expect a master.
  - **A packed audio segment starts with ID3v2 tags, and a segment can hold more
    than one.** The stations of one network send two: a timestamp and the title of
    the track. `Membrane.AAC.Parser` stops with `:invalid_adts_header` on any tag
    that reaches it. `MyHiFi.Player.PackedAudio` removes them all.
  - **8 stations send MP3 inside MPEG-TS**, with the codec `mp4a.40.34`, so HLS is
    not only AAC. `membrane_mp3_mad_plugin` then stops at the first frame, because
    it asks for the time of a frame before it holds a format. A timestamp on the
    buffer is what starts that, so `MyHiFi.Player.MpegAudio` removes the
    timestamp. `MyHiFi.Player.HttpSource` sets none, which is why a Shoutcast MP3
    stream never showed this.
- **`kim_hls` names `req` as a test dependency of its own**, so
  `HLS.Storage.Req` exists in a build or does not, and the answer depends on the
  order that the dependencies compile in. `MyHiFi.Player.Hls.Storage` is ours, and
  it holds the timeouts of this firmware. Do not use the one from `kim_hls`.
- **Two traps of SQLite, and each one cost a debugging cycle.** `ago/2` gives no
  answer on AshSqlite: a filter on it matches no row, and a calculation of it gives
  `nil` for a row that holds a date. Use `datetime_add(now(), -n, :unit)` instead.
  And Oban cannot make a job unique when one argument holds `nil`, because its
  SQLite engine compares the arguments as JSON. AshOban always puts `tenant: nil` in
  them, so no trigger job of this firmware is unique. Give the trigger a `where`
  instead, and let the second job cancel itself.
- **If a later version needs another binary, use NBPR**, not a Nerves system
  fork. See <https://github.com/jimsynz/nbpr>. NBPR ships binaries and shared
  libraries, and no header files.
- **NBPR publishes no artefact for this system, so every build makes one.** NBPR
  publishes for the stock Nerves systems, and the cache key of an artefact holds
  the name and the version of the system, so `mix nbpr.fetch` on
  `myhifi_rpi0_2` always builds from source. A source build needs a Buildroot
  backend. A laptop with `docker` gets one by itself. The CI container holds no
  `docker` and no `podman`, so `ci.yml` names `nbpr_source_build: true`, and the
  shared workflow then sets `NBPR_BUILD_BACKEND=shell` and installs the four
  Buildroot packages that the image lacks. A new version of the system starts a
  new build of every `nbpr_*` package, and that build takes 10 minutes.
- **A skip moves the reader, and it does not start a pipeline again.**
  `MyHiFi.Output.APlaySink` starts `aplay` for each pipeline, `aplay` opens the sound
  card, and the card is the part of this board that fails. A start also holds a silence
  of about one second, and a skip is a control that a person presses again and again.
  The player therefore calls the pipeline and `MyHiFi.Player.FileSource` moves the byte
  that it reads. **A skip needs no bitrate either:** `MyHiFi.Player.Mp3Frame` walks the
  frame headers and `MyHiFi.Player.Skip` measures the span that it lands on, because 11
  of 46 real episodes hold more than one bitrate. This holds for MP3 alone, and 8771 of
  8773 measured episodes hold `audio/mpeg`.
- **A peripheral renders itself.** Do not build a central renderer and do not
  send pixels or frames to a screen. Send it typed events. A 128 by 64
  monochrome screen and a 320 by 240 colour screen need different layouts, and
  each one decides its own.
- **Screens and controls share one behaviour.** Do not split them. On the PiTFT
  the ILI9341 screen and the STMPE610 touch controller share SPI0, so one process
  must own the bus. `MyHiFi.Peripheral.PiTft` draws and publishes touch events.
- **Emerge draws the device screen, through its raster part alone.**
  `EmergeSkia.render_to_pixels/2` gives the pixels back to the caller, and
  `MyHiFi.Peripheral.PiTft` writes them to the ILI9341 over SPI. Do not call
  `EmergeSkia.start/1` and do not add a display server: this firmware drives no
  window and no DRM device. Three traps, and each one costs a build to find.
  - **`mix.exs` sets `TARGET_VENDOR` to `"unknown"`, and it must stay that way.**
    `rustler_precompiled` reads the same four variables that Bundlex reads. Emerge
    publishes `aarch64-unknown-linux-gnu`, so `"nerves"` there makes it compile
    Skia from source. Bundlex stores the value and reads it nowhere else, and
    `Membrane.PrecompiledDependencyProvider` matches the architecture, the
    operating system and the ABI, and never the vendor.
  - **`config/target.exs` must name `compiled_backends`.**
    `EmergeSkia.BuildConfig` sees `MIX_TARGET` and chooses `[:drm]` by itself, and
    that variant names `libgbm`, which needs Mesa. `[]` is what this firmware wants,
    and Emerge publishes no artefact for it, so `[:wayland]` is the choice and
    nothing calls into it.
  - **`nerves_system_myhifi_rpi0_2` holds `libxkbcommon` for the NIF and for
    nothing else.** The dynamic loader reads the name when it opens the NIF. NBPR
    cannot serve this: it sets `LD_LIBRARY_PATH` at boot, glibc reads that variable
    one time when the process starts, and a NIF of the BEAM is not a program that a
    port starts.
- **Web config suits an appliance, not a cloud app.** `config/target.exs` sets
  port 80, `server: true`, and `check_origin: false`, because a device answers on
  its IP address and on more than one mDNS name. `MyHiFi.Application` calls
  `MyHiFi.DeviceSecrets.put/1` before it starts the endpoint, which reads the
  endpoint secret and the LiveView signing salt from `/root` and writes each one
  on the first boot. That runs for a target build in any `MIX_ENV`, and never on
  the host. A signing salt is not a secret, and each place that uses one derives
  the key from the salt and the endpoint secret. The salt of a device is therefore
  defence in depth, and the session cookie salt of `MyHiFiWeb.Endpoint` stays
  fixed, because a module attribute cannot hold a value for each device. Do not restore `force_ssl`, and
  do not make a boot depend on an environment variable: a device has nothing to
  set one.
- **Setup mode and normal operation cannot happen together.** The Wi-Fi wizard
  serves on port 80, and its captive portal needs port 80 as well.
  `MyHiFiWeb.Endpoint` uses the same port. `MyHiFi.Application` therefore starts
  the wizard or the web interface, and never both. See `MyHiFi.Setup` and section
  14 of the spec.
- **A target-only module must hold no reference on the host.** `vintage_net` and
  `vintage_net_wizard` are target dependencies, so the host build breaks the
  compiler check. Wrap the module in `if Mix.target() != :host do`, as
  `MyHiFi.Setup.Monitor` does, or branch the function bodies, as `MyHiFi.Setup`
  does. `config/target.exs` cannot solve this, and neither can an empty list in
  `Config`.
- **The firmware migrates itself.** `MyHiFi.Application` calls
  `MyHiFi.Migrator.migrate/0` before it starts the supervision tree, and not as a
  child of it, because Oban queries its own tables as soon as it starts. Like the
  secret, this runs for a target build in any `MIX_ENV` and never on the host, so
  development and test keep using `mix ash.setup`.
- **The buffer of a live stream stays in memory.** It is a ring buffer of compressed
  bytes, placed before the decoder. Never buffer a live stream on the SD card, and
  never buffer raw samples anywhere. Such a buffer writes all the time, and that
  shortens the life of the card.

  **A podcast episode is not a live stream, and it goes on the card.** It is a finite
  file, so this device writes it one time and then reads it. That is what makes the
  audio correct and the resume exact: an episode arrives faster than its own audio,
  and the demand of Membrane cannot pace a socket that Finch owns. See
  `MyHiFi.Player.Download` and section 13 of the specification.

## Structure

The software has four layers. They talk through Phoenix PubSub.

1. **Sources** find audio and give a playable stream. A source implements
   `MyHiFi.Source`. The first source is internet radio. **A source names its own
   settings**, with `settings/0` and `settings_actions/0`, and it checks its own
   values in `put_settings/1`. The settings page draws that list and holds no
   knowledge of any source. A person can also take a source out of use, and
   `MyHiFi.Playback.enable_source/2` is the one command for that.
2. **The player** runs the Membrane pipeline and holds the playback state.
3. **Outputs** send samples to hardware. An output implements `MyHiFi.Output`.
4. **Peripherals** own a piece of hardware. A peripheral implements
   `MyHiFi.Peripheral`. A screen, a knob, and a touch panel are all peripherals,
   and they share one behaviour. A peripheral gets typed events, it owns its
   layout, fonts, and scroll window, and it publishes what the person does.
5. **`MyHiFi.DeviceUi`** holds the navigation state for the device screen. It
   receives the input events, and it publishes the view events and the hints. It
   owns the selected index and the list, because the knob needs a detent count
   and only `MyHiFi.DeviceUi` knows the length of the list.

Every message is a struct from `MyHiFi.Event`, on one of five topics: `:player`,
`:source`, `:view`, `:input`, and `:hint`. Never send a bare tuple or a map. A part
never calls another part directly. A peripheral declares its topics with
`subscriptions/0`, so a knob does not wake once a second for a progress event.
`:source` carries `Source.Changed`, which says that the entries inside one
container changed. A source that reads a service behind the page sends it, and a
user interface that shows that container reads it again.

Ash with SQLite holds the data, on the application data partition. That
partition mounts at `/root` on a Nerves target, and it is the only writable
storage. There is no `/data`. Oban does the
background work.

## Rules for this project

- Write every text artefact in ASD-STE100 Simplified Technical English. That
  covers `README.md`, this file, module and function documentation, code
  comments, commit messages, issue titles and bodies, pull request descriptions,
  and messages to the user. See the STE section below.
- Use New Zealand English spelling. Write "licence" for the noun and "colour",
  not the American forms.
- Do not add a source, an output, or a peripheral without the behaviour. The point
  of the behaviour is that the rest of the firmware never changes. A person must
  be able to add an SSD1306 screen, or a different DAC, or a new music service,
  without a change to the player or to the user interface.
- A Hex package does not always work on `myhifi_rpi0_2`. Check the Nerves
  system, and
  look for native code, before you add the package.
- **The code is the specification, and this repository holds no `docs/`.** A
  specification in prose goes out of date, and then it lies. Put the reason for a
  decision in the moduledoc of the module that holds the decision, and put the
  reason for a change in the commit message. Do not write a plan document, and do
  not restore `docs/`.

## Simplified Technical English

STE is easy to read wrong, because ordinary technical English feels correct. Each
line below is a mistake that this project has already made and corrected.

- **One word has one meaning.** Do not write "keep a station" for a favourite,
  and do not write "drop it" for the opposite. Write "make a station a
  favourite", and write "remove that mark".
- **No metaphors.** A task is not a "gate". Memory does not "cost" anything, it
  "needs" it. A caller does not "walk" a tree, it "moves through" it. A stream has
  no "edge", it has a "current point".
- **No phrasal verbs.** Write "uses X instead", and not "falls back to X". Write
  "get access", and not "log in".
- **Use each word in its approved part of speech.** A variable "becomes"
  `unknown`. It does not "default to" it.
- **Avoid these words**, which are not approved: assume, elapsed, nobody,
  recover, stall, throwaway. Write: the plan is correct only if; the time from the
  start; no person; continue; interruption; temporary.
- **Keep sentences short.** 20 words for an instruction, and 25 for a
  description. Split a long sentence, and do not join clauses with a comma.
- **Use the active voice, the present tense, and the imperative** for each
  instruction. Give one instruction in each sentence.
- **Use articles.** Write "the device", and not "device".

A code identifier, a product name, and a protocol name are technical names. Use
them as they are, even when the word is not on the approved list. `aplay`,
`Membrane.HLS.Source`, Shoutcast, and HE-AAC are all correct.

The rule covers the text that this project writes. It does not cover text from
another source. Leave the generator comments in `config/target.exs` and in
`config/host.exs` as they are, and leave the Nerves text in `README.md` as it is.
A rewrite of that text gives no benefit, and it hides the difference from the
template.

<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

[usage_rules usage rules](deps/usage_rules/usage-rules.md)
<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
[usage_rules:elixir usage rules](deps/usage_rules/usage-rules/elixir.md)
<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
[usage_rules:otp usage rules](deps/usage_rules/usage-rules/otp.md)
<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
