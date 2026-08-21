# MyHiFi

MyHiFi is Nerves firmware for a home audio player. It connects to a home stereo
and behaves like a normal stereo component. `docs/spec.md` holds the
specification. Read it before you make a design decision.

Licence: Apache-2.0.

## What you must know

- **Target board.** Raspberry Pi Zero 2 W, Nerves target `rpi0_2`. It has 4
  cores and one USB data port. It holds 512 MB of RAM, and Linux sees 301 MB of
  it, because CMA and the GPU reserve the rest. A measurement on 2026-08-21 gave
  176 MB free with the skeleton in operation. Keep the memory use small.
- **The USB port holds the DAC.** For this reason the knob uses I2C, not USB.
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
  `CROSSCOMPILE` and `REBAR_TARGET_ARCH`. Without the four variables the
  precompiled download fails. The build then uses `pkg-config` instead, and it
  stops with an error. See section 6.4 of the specification.
- **HLS is in scope for version 1.** `membrane_hls_plugin` gives
  `Membrane.HLS.Source` and `Membrane.HLS.SourceBin`, and it holds no native
  code. 19% of New Zealand stations need HLS, and that includes every commercial
  network.
- **If a later version needs another binary, use NBPR**, not a Nerves system
  fork. See <https://github.com/jimsynz/nbpr>. NBPR ships binaries and shared
  libraries, and no header files.
- **A peripheral renders itself.** Do not build a central renderer and do not
  send pixels or frames to a screen. Send it typed events. A 128 by 64
  monochrome screen and a 320 by 240 colour screen need different layouts, and
  each one decides its own.
- **Screens and controls share one behaviour.** Do not split them. On the PiTFT
  the ILI9341 screen and the STMPE610 touch controller share SPI0, so one process
  must own the bus. `MyHiFi.Peripheral.PiTft` draws and publishes touch events.
- **The device screen uses Vivid**, not Scenic. See
  <https://harton.dev/james/vivid>. Vivid is a pure Elixir 2D renderer. From
  v1.0.0 it reads OpenType, TrueType, WOFF, and BDF fonts. It draws no colour
  raster yet, so cover art waits on upstream Vivid work. `Vivid.Bitmap` holds one
  bit for each cell and serves the fonts. It is not an image.
- **Web config suits an appliance, not a cloud app.** `config/target.exs` sets
  port 80, `server: true`, and `check_origin: false`, because a device answers on
  its IP address and on more than one mDNS name. `MyHiFi.Application` calls
  `MyHiFi.SecretKeyBase.put/1` before it starts the endpoint, which reads a
  secret from `/root` and writes one on the first boot. That runs for a target
  build in any `MIX_ENV`, and never on the host. Do not restore `force_ssl`, and
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
- **The stream buffer stays in memory.** It is a ring buffer of compressed bytes,
  placed before the decoder. Never buffer the stream on the SD card, and never
  buffer raw samples.

## Structure

The software has four layers. They talk through Phoenix PubSub.

1. **Sources** find audio and give a playable stream. A source implements
   `MyHiFi.Source`. The first source is internet radio.
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

Every message is a struct from `MyHiFi.Event`, on one of four topics: `:player`,
`:view`, `:input`, and `:hint`. Never send a bare tuple or a map. A part never
calls another part directly. A peripheral declares its topics with
`subscriptions/0`, so a knob does not wake once a second for a progress event.

Ash with SQLite holds the data, on the application data partition. That
partition mounts at `/root` on a Nerves target, and it is the only writable
storage. There is no `/data`. Oban does the
background work.

## Rules for this project

- Write every text artefact in ASD-STE100 Simplified Technical English. That
  covers `docs/`, `README.md`, this file, module and function documentation, code
  comments, commit messages, issue titles and bodies, pull request descriptions,
  and messages to the user. See the STE section below.
- Use New Zealand English spelling. Write "licence" for the noun and "colour",
  not the American forms.
- Do not add a source, an output, or a peripheral without the behaviour. The point
  of the behaviour is that the rest of the firmware never changes. A person must
  be able to add an SSD1306 screen, or a different DAC, or a new music service,
  without a change to the player or to the user interface.
- A Hex package does not always work on `rpi0_2`. Check the Nerves system, and
  look for native code, before you add the package.
- Keep the specification current. If a decision changes, change `docs/spec.md`
  in the same commit.

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
