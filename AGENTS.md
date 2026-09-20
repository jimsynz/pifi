# PiFi

PiFi is Nerves firmware for a home audio player. It connects to a home stereo
and behaves like a normal stereo component. The code is the specification: read
the moduledoc of the part that you change before you make a design decision.

Licence: Apache-2.0.

## What you must know

- **Target board.** Raspberry Pi Zero 2 W, Nerves target `pifi_rpi0_2`. That
  target is a custom system, not the stock `rpi0_2`. See
  <https://harton.dev/mypihifiguy/nerves_system_pifi_rpi0_2>. The stock system
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
  `PiFi.Output.Alsa.sink_spec/1` names it in the place of `plughw`. **Do not tell
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
  the station record. `PiFi.Player.Hls` reads the playlist and gives three
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
    that reaches it. `PiFi.Player.PackedAudio` removes them all.
  - **8 stations send MP3 inside MPEG-TS**, with the codec `mp4a.40.34`, so HLS is
    not only AAC. `membrane_mp3_mad_plugin` then stops at the first frame, because
    it asks for the time of a frame before it holds a format. A timestamp on the
    buffer is what starts that, so `PiFi.Player.MpegAudio` removes the
    timestamp. `PiFi.Player.HttpSource` sets none, which is why a Shoutcast MP3
    stream never showed this.
- **`kim_hls` names `req` as a test dependency of its own**, so
  `HLS.Storage.Req` exists in a build or does not, and the answer depends on the
  order that the dependencies compile in. `PiFi.Player.Hls.Storage` is ours, and
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
  `pifi_rpi0_2` always builds from source. A source build needs a Buildroot
  backend. A laptop with `docker` gets one by itself. The CI container holds no
  `docker` and no `podman`, so `ci.yml` names `nbpr_source_build: true`, and the
  shared workflow then sets `NBPR_BUILD_BACKEND=shell` and installs the four
  Buildroot packages that the image lacks. A new version of the system starts a
  new build of every `nbpr_*` package, and that build takes 10 minutes.
  - **A build publishes the result only when it holds the credentials of the
    registry.** `config/target.exs` names `registry`, and `NBPR.OCI.Client` reads
    `NBPR_REGISTRY_USERNAME` and `NBPR_REGISTRY_TOKEN`. `mix nbpr.fetch` finishes a
    package and then stops with `registry_credentials_required` when it finds neither
    one, so `publish_after_build` reads the two variables. This is the rule that
    `nerves_hub_link` follows as well: an absent secret turns the feature off, and it
    does not stop the build.
- **A production firmware holds no SSH daemon, and `mix upload` needs one.**
  `config/target.exs` gives `nerves_ssh` an application environment only when
  `Mix.env()` is `dev`. A `MIX_ENV=prod` image on a board that a hand cannot reach
  is therefore one way, and the SD card is the only way back. **NervesCloud is what
  makes a production image safe to send.** `nerves_hub_link` connects out to
  `devices.nervescloud.com`, so it opens no port, and it carries a firmware and a
  console. `.envrc` reads the two secrets from 1Password, and a build that holds
  neither one writes `connect: false`. Two traps, and the NervesCloud section of
  `config/target.exs` holds the reasons.
  - **`data_path` must not keep its default of `/data/nerves-hub`**, because this
    system has no `/data`. It holds the archives and the files that a person sends
    to the console. A firmware update streams into `fwup` and needs no file.
  - **An absent secret needs `connect: false`.** This is the opposite of
    `nerves_ssh`. `NervesHubLink.Application.start/2` starts its supervisor unless a
    person says not to, and `host` then becomes `localhost`.
  - **A credential trims to what it is.** A field of a password manager can hold a
    space at its end that no person sees. Such a key makes the wrong HMAC, and the
    socket upgrade answers 401 with no body and no reason. Read the length of the
    key on the device before you look anywhere else.
- **A skip moves the reader, and it does not start a pipeline again.**
  `PiFi.Output.APlaySink` starts `aplay` for each pipeline, `aplay` opens the sound
  card, and the card is the part of this board that fails. A start also holds a silence
  of about one second, and a skip is a control that a person presses again and again.
  The player therefore calls the pipeline and `PiFi.Player.FileSource` moves the byte
  that it reads. **A skip needs no bitrate either:** `PiFi.Player.Mp3Frame` walks the
  frame headers and `PiFi.Player.Skip` measures the span that it lands on, because 11
  of 46 real episodes hold more than one bitrate.
  - **The shape of a frame gives two strategies, and `PiFi.Player.Skip.place/5`
    chooses by the codec.** MP3 and AAC name the length of each frame, so this
    firmware walks the frames and sums the time. **A FLAC header names neither a
    length nor a bitrate**: it names the number of the frame, or of the first sample
    of it, so `PiFi.Player.FlacFrame` bisects the file instead and reports a time
    that is exact and not measured.
  - **A skip of FLAC that lands one byte inside a frame plays nothing at all.** A
    measurement on the host on 2026-09-11 gave
    `FLAC__STREAM_DECODER_ERROR_STATUS_LOST_SYNC after processing 0 samples` and no
    audio. A sync word alone cannot be trusted, and the other two readers confirm a
    frame with the frame that follows it, which this one cannot. **The CRC-8 of the
    header is what makes a FLAC frame real.**
  - **A skip of FLAC needs no restart of the decoder.** The same measurement spliced
    the frames of one place on to the audio of another, forward and backward, and
    `flac --decode --stdout --silent -` gave every remaining sample. Each frame
    carries its own rate, channel count and width, so the program needs neither the
    `fLaC` marker nor the metadata again.
  - `PiFi.Player.Skip.frames/1` is the one list of the codecs that this firmware
    reads the frames of. `PiFi.Player.skippable?/1` and
    `PiFi.Player.FileSource.rewound/3` both read it, so a new codec needs a reader
    and one line.
- **A peripheral renders itself.** Do not build a central renderer and do not
  send pixels or frames to a screen. Send it typed events. A 128 by 64
  monochrome screen and a 320 by 240 colour screen need different layouts, and
  each one decides its own.
- **A peripheral is out of use until a person says that the part is wired.** The
  same image runs on a board with a screen and on a board with none, and a bus
  with nothing on it gives an error at each start. `config/target.exs` names what
  this firmware knows, and `PiFi.Peripheral.enabled?/1` reads the settings for
  what the board holds. This is the opposite of `PiFi.Source.enabled?/1`, and
  the hardware is the reason. `PiFi.Peripheral.Supervisor` starts with no child,
  because a child that fails to start stops the start of a whole supervisor and a
  screen must never keep the music from playing.
- **Screens and controls share one behaviour.** Do not split them. On the PiTFT
  the ILI9341 screen and the STMPE610 touch controller share SPI0, so one process
  must own the bus. `PiFi.Peripheral.PiTft` draws, and it publishes what a person
  presses. A peripheral that reads hardware names
  `c:PiFi.Peripheral.handle_info/2`, because a GPIO line speaks to the process
  that holds it and not to a topic.
- **The backlight of the PiTFT is on GPIO 2 of the STMPE610, and the four buttons
  are on lines 18, 27, 22 and 23.** Pin 18 of the Raspberry Pi reaches the light on
  no board that this firmware drives. The Adafruit PiTFT joins the two with a solder
  jumper named `Lite #18`, the Jaycar XC9022 clone that this device holds has none,
  and the STMPE line takes precedence over that pin in any case. A write to pin 18
  therefore changed nothing, standby slept the panel under a light that stayed on,
  and a panel that sleeps shows white. **Line 18 is a button.** Read the order of the
  row one button at a time, and read it from
  `PiFi.Event.Input.ButtonPressed`: four presses in one go give a list of events
  that holds no order of place, and two builds named the wrong row from such a list.
  `PiFi.DeviceUi` decides what a place in the row means, and the driver names the
  place alone.
- **A dark screen has two causes, and a press does not mean the same thing under each
  one.** Standby stops the audio. A blank leaves the audio playing and turns the light
  off, because the light is a large part of what a portable device takes from its cell.
  `PiFi.DeviceUi` owns the period and publishes `PiFi.Event.View.ScreenBlanked`, and
  each screen decides what dark means for it. Two rules keep the two apart. **The first
  press of a blanked screen brings the light back and does nothing else**, and a press
  in standby must leave standby, so `PiFi.DeviceUi` reads the player before it blanks.
  **A peripheral clears its blank when it dozes**, because a blank that survived standby
  would stop the draw, and the light would then come on over a panel that lost its
  frame.
- **Emerge draws the device screen, through its raster part alone.**
  `PiFi.Screen.Renderer` starts one headless renderer for each screen, and
  `PiFi.Peripheral.PiTft` writes the pixels to the ILI9341 over SPI. Do not add a
  display server: this firmware drives no window and no DRM device. Five traps, and
  each one costs a build to find.
  - **`mix.exs` sets `TARGET_VENDOR` to `"unknown"`, and it must stay that way.**
    `rustler_precompiled` reads the same four variables that Bundlex reads. Emerge
    publishes `aarch64-unknown-linux-gnu`, so `"nerves"` there makes it compile
    Skia from source. Bundlex stores the value and reads it nowhere else, and
    `Membrane.PrecompiledDependencyProvider` matches the architecture, the
    operating system and the ABI, and never the vendor.
  - **`rustler_precompiled` shares one cache between targets, in the way that
    Bundlex does.** It keeps each NIF under `deps/emerge/priv/native`, and
    `_build/<target>/lib/emerge/priv` is a symbolic link to it, so a host build
    leaves an x86 library where a target release copies it and the Nerves scrub step
    stops. The release step `prune_foreign_rustler/1` in `mix.exs` makes the
    directory real and removes each NIF that does not name the target triple.
  - **`config/config.exs` must name `compiled_backends`, and the value is `[]`.**
    `EmergeSkia.BuildConfig` chooses `[:drm]` by itself, that variant names `libgbm`,
    and `libgbm` needs Mesa. Emerge 0.4 publishes an artefact for `[]`, which is the
    `--raster` NIF, so this project needs neither Mesa nor `libxkbcommon` and it
    compiles nothing from source. **The line belongs in the shared config, and not in
    `config/target.exs`.** The host runs the tests of each screen, so a host that names
    no value downloads the DRM NIF and 132 of those tests stop with `EmergeSkia.Native
    is not available`.
  - **Emerge 0.4 draws for a renderer, and not for a call.**
    `EmergeSkia.render_to_pixels/2` took a tree in 0.3 and reads the last frame of a
    running renderer now. `EmergeSkia.start/1` gives a renderer, each
    `EmergeSkia.upload_tree/2` sends one frame to the process that started it, and a
    frame arrives for an unchanged tree as well. `PiFi.Screen.Renderer` holds that
    exchange for a screen and `PiFi.Test.Drawing` holds it for a test.
  - **Emerge refuses a runtime path by its extension, and it reads no byte to
    decide.** The list that it holds by default names `.png`, `.jpg` and five other
    types, and a name of the cache carries no type, so a thumbnail is
    `<hash>.thumbnail`. Emerge drew the mark that it draws for a picture that it
    cannot read, and the screen showed that in the place of the artwork.
    `PiFi.Screen.Renderer.assets/0` names the two that this firmware gives it:
    `.thumbnail` for the cache, and `.png` for the picture that the firmware ships
    for an idle screen.
  - **`PiFi.Screen.Style` holds every colour, size and edge that a screen draws
    with, and a part names none of its own.** The screens follow the neubrutalist
    style of the website: flat colour, a hard border, an offset shadow with no blur,
    and no round corner. The ground is dark and **the offset shadow is cyan**, because
    a black shadow on a near black ground is nothing at all. `Emerge.UI.Border.shadow/1`
    blurs by 10 pixels when a caller says nothing, so the blur must be 0 each time.
  - **The display face ships in `priv/fonts` and each renderer loads it.** Neither
    this firmware nor the Nerves system held a font before, so the screens drew in the
    face that Skia uses when it finds no other. `EmergeSkia.load_font_file/5`
    registers a file for **one renderer**, so `PiFi.Screen.Renderer.start/2` loads it
    each time. A renderer that cannot read the file still starts: a screen in another
    face is one that a person can read, and a screen that will not start is a black
    panel.
  - **`Emerge.UI.key/1` cannot name a part for a test to find.** Emerge keeps a key
    for reconciliation and it raises `All siblings must have key when any key is
    provided`, so one named element means that every element beside it needs a name.
    `PiFi.Test.Tree` therefore reads the tree without names: `texts/1` gives the words
    that a person reads, and `shows?/2` asks whether the screen holds the tree that a
    part gives. **A test of a layout reads the tree, and never the pixels.** A test of
    a part, such as `PiFi.Screen.Battery`, still reads the pixels, because the shape
    is the whole of what that part does.
  - **The idle screen of a device that a person gave no picture draws the mark of the
    product.** `priv/splash` holds one PNG for each screen, named
    `<product>-<width>x<height>.png`, and `PiFi.Device.Identity.shipped_splash/1`
    reads it. **The file is the size of the screen**: another size costs a scale on each
    draw, and a screen that had to crop would lose the ends of the waveform of that
    artwork. A new screen therefore needs a file and no code. The mark comes from the
    SVG of the website, and `assets/logo/README.md` holds the source files and the one
    rule that matters: **render at four times the size and scale the answer down**, or
    the ground shows through the seam between the rectangles of each letter.

    **A screen draws no name over the mark of the product**, because the mark carries
    that name already. A device that a person named draws a card with the name in it.
- **A device upgrades itself from the releases of the forge.** A tag of the form
  `v1.2.3` builds a production firmware for each target and the shared CI workflow
  attaches it to a release with a `.sha256` beside it, so the forge is the whole of the
  release channel and this firmware needs no service of its own.
  `PiFi.Device.Upgrade.Check` asks once a day, the settings page holds the control, and
  `PiFi.Device.Upgrade.Install` writes the file to `/root`, checks the digest, and hands
  it to `fwup --task upgrade`. **A device never upgrades by itself**: a stereo that
  restarted in the middle of a record is one that a person stops trusting.
- **Web config suits an appliance, not a cloud app.** `config/target.exs` sets
  port 80, `server: true`, and `check_origin: false`, because a device answers on
  its IP address and on more than one mDNS name. `PiFi.Application` calls
  `PiFi.DeviceSecrets.put/1` before it starts the endpoint, which reads the
  endpoint secret and the LiveView signing salt from `/root` and writes each one
  on the first boot. That runs for a target build in any `MIX_ENV`, and never on
  the host. A signing salt is not a secret, and each place that uses one derives
  the key from the salt and the endpoint secret. The salt of a device is therefore
  defence in depth, and the session cookie salt of `PiFiWeb.Endpoint` stays
  fixed, because a module attribute cannot hold a value for each device. Do not restore `force_ssl`, and
  do not make a boot depend on an environment variable: a device has nothing to
  set one.
- **Setup mode and normal operation cannot happen together.** The Wi-Fi wizard
  serves on port 80, and its captive portal needs port 80 as well.
  `PiFiWeb.Endpoint` uses the same port. `PiFi.Application` therefore starts
  the wizard or the web interface, and never both. See `PiFi.Setup` and section
  14 of the spec.
- **Three keys of `Nerves.Runtime.KV` hold what this device is called and what it
  looks like, and `fwup` provisions all three.** `pifi_device_name` is what a person
  called this device. `pifi_product_name` is what the product is called, which every
  unnamed device answers to, and `pifi_splash_name` names the artwork in
  `priv/splash`. **One firmware therefore serves several products**: a person who makes
  an SD card for another brand writes two keys, and neither the name nor the picture
  needs a build of its own. `provisioning.conf` of the Nerves system is where such a
  line goes, beside the serial number.
- **A board that was made when the product was called MyHiFi holds the old keys, and
  `PiFi.Device.Identity` reads both.** No upgrade task runs `uboot_clearenv`, so the
  old block survives a new firmware. A read asks for the new key and uses
  `myhifi_device_name` and its two neighbours when the new one is absent. **A write
  always uses the new key**, so the old one stays in the block, unread, until a person
  writes a card. `PiFi.Migrator.carry_over/0` does the same for the database: it moves
  `/root/my_hi_fi.db` and its `-wal` and `-shm` files to `/root/pifi.db` before the
  repo opens, because the adapter makes an empty database when it finds no file and a
  person would meet an empty catalogue.
- **The name of the device lives in `Nerves.Runtime.KV`, and not in the settings
  table.** The wizard above starts before the Repo does, and the access point carries
  that name, so a name in the database is unreadable in the one mode that needs it.
  `fwup` writes the same block, so a factory can name a device, and no upgrade task of
  the system runs `uboot_clearenv`, so the name goes when a person writes an SD card
  and at no other time. **The name of the board does not move**: erlinit sets the
  hostname at the boot, and nothing can change it after that, so
  `MdnsLite.set_hosts/1` puts the name of the person first and the device answers for
  both. The picture of the idle screen is not in that block: it is bytes, so
  `PiFi.Artwork` holds it under the hash of those bytes and each screen reads the
  thumbnail of it. See `PiFi.Device.Identity`.
- **A target-only module must hold no reference on the host.** `vintage_net` and
  `vintage_net_wizard` are target dependencies, so the host build breaks the
  compiler check. Wrap the module in `if Mix.target() != :host do`, as
  `PiFi.Setup.Monitor` does, or branch the function bodies, as `PiFi.Setup`
  does. `config/target.exs` cannot solve this, and neither can an empty list in
  `Config`.
- **The firmware migrates itself.** `PiFi.Application` calls
  `PiFi.Migrator.migrate/0` before it starts the supervision tree, and not as a
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
  `PiFi.Player.Download` and section 13 of the specification.

## Structure

The software has four layers. They talk through Phoenix PubSub.

1. **Sources** find audio and give a playable stream. A source implements
   `PiFi.Source`. The first source is internet radio. **A source names its own
   settings**, with `settings/0` and `settings_actions/0`, and it checks its own
   values in `put_settings/1`. The settings page draws that list and holds no
   knowledge of any source. **A source also names how its items read and in what
   order**, with `listing/1`: an album holds its tracks by number and a show holds its
   episodes by date with the newest first, and a page that held either rule listed
   every album alphabetically. It names typed facts and never text, because one fact
   reads as "44m left" in a browser and as "44 min" on a screen of 240 pixels. A person can also take a source out of use, and
   `PiFi.Playback.enable_source/2` is the one command for that.
2. **The player** runs the Membrane pipeline and holds the playback state.
3. **Outputs** send samples to hardware. An output implements `PiFi.Output`.
4. **Peripherals** own a piece of hardware. A peripheral implements
   `PiFi.Peripheral`. A screen, a knob, and a touch panel are all peripherals,
   and they share one behaviour. A peripheral gets typed events, it owns its
   layout, fonts, and scroll window, and it publishes what the person does.
5. **`PiFi.DeviceUi`** holds the navigation state for the device screen. It
   receives the input events, and it publishes the view events and the hints. It
   owns the selected index and the list, because the knob needs a detent count
   and only `PiFi.DeviceUi` knows the length of the list.

Every message is a struct from `PiFi.Event`, on one of five topics: `:player`,
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

- **Write plain, direct English.** That covers everything: `README.md`, this file,
  module and function documentation, code comments, commit messages, issue and
  pull request text, and every word that a person reads in the product. Write the
  way you would explain the thing to another developer who is about to change it.
  Contractions are fine. Prefer a concrete noun to an abstract one, and a short
  sentence to a long one. See the writing section below.
- Use New Zealand English spelling. Write "licence" for the noun and "colour",
  not the American forms.
- Do not add a source, an output, or a peripheral without the behaviour. The point
  of the behaviour is that the rest of the firmware never changes. A person must
  be able to add an SSD1306 screen, or a different DAC, or a new music service,
  without a change to the player or to the user interface.
- A Hex package does not always work on `pifi_rpi0_2`. Check the Nerves
  system, and
  look for native code, before you add the package.
- **The code is the specification, and this repository holds no `docs/`.** A
  specification in prose goes out of date, and then it lies. Put the reason for a
  decision in the moduledoc of the module that holds the decision, and put the
  reason for a change in the commit message. Do not write a plan document, and do
  not restore `docs/`.

## Writing

This project used to write everything in ASD-STE100 Simplified Technical English.
That rule is gone. It banned contractions and phrasal verbs and held a list of
approved words, and the result read like a translated manual: a button that said
"Put in use" where a person expects "Enable", and a moduledoc where every verb was
"holds".

**Deleting a rule about register does not leave neutral prose.** Strip out one
voice and the writing drifts into another, usually a literary one. So here is the
positive rule.

### For documentation, comments and commit messages

The reader is a developer who is about to change this code. Write for them.

- **Say why, not what.** The code says what it does. A comment earns its place by
  holding the reason, the measurement, or the trap. "The dwc2 controller handles a
  44.1 kHz packet badly" is worth a line. "Set the rate" is not.
- **Name the thing that bit you.** A moduledoc that records a wrong turn saves the
  next person a build. Most of the good comments in this repository are of that
  shape, and they should stay that shape.
- **Vary the verbs.** Under the old rule almost everything "held" something. A
  module makes a decision, a row carries a number, a cache keeps a file, a
  function returns a value.
- **Use ordinary technical English.** Contractions are fine. "Falls back to" and
  "walks the tree" are fine, and they are clearer than the paraphrases that the
  old rule forced.
- No metaphor for its own sake, and no aphorisms. Say the thing plainly.

### For the words a person reads in the product

Every label, button, empty state, flash message and description of the web
interface, and every word that a screen of the device draws.

- **A control says what it does.** "Enable" and "Disable", not "Put in use".
- **Do not let the device narrate itself in the third person.** Write "Couldn't
  play that", not "The device could not play that". Where the subject matters, use
  the name of the product: "PiFi enters standby after 20 minutes".
- **Say "you" for the person.**
- **An empty state says what to do next**, not merely that there is nothing there.
- **An error says what happened and what a person can do**, and it never makes them
  feel stupid.
- Keep it short. A label is one or two words. A description is one sentence where
  one sentence does.

This is the rule that `CLAUDE.md` of the website repository holds, and the two
must sound like one product.

### What stays

Use New Zealand English spelling: "licence" for the noun, "colour", "behaviour".

**Text from a generator is not ours to rewrite.** The comments that Nerves wrote
into `config/target.exs` and `config/host.exs`, and the "Targets" and "Learn more"
sections of `README.md`, stay as they are. Rewriting them gains nothing and hides
the difference from the template, which is the thing a person wants to see when
the template moves.

**The existing moduledocs are still in the old voice, and that is fine.** They are
accurate, and rewriting several thousand lines of them buys nothing. Fix the voice
of a docstring when you are already changing that code, and leave the rest alone.

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
