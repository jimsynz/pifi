# Plan: the 2.8 inch PiTFT screen, drawn with Emerge

- Date: 2026-08-26
- Status: steps 1 to 5 of section 11 are done, and step 6 is done in the system
  repository and not built. Nothing is measured on the board. Section 3.1 way 1 is
  the way that this took.
- Language: this document uses ASD-STE100 Simplified Technical English.

## 1. Purpose

Section 15 of `docs/spec.md` says that no renderer is chosen for the device screen,
and that the choice must draw a colour raster and draw text from a font. This plan
proposes Emerge, and it holds what a measurement of Emerge gave.

The plan covers the screen only. The STMPE610 touch controller, `MyHiFi.DeviceUi`,
and the `:view`, `:input` and `:hint` events come after the screen draws.

## 2. What Emerge is

See <https://hex.pm/packages/emerge>, version 0.3.4, Apache-2.0. It is a declarative
user interface library. A caller writes a tree of elements, and a Rust NIF lays the
tree out and draws it with Skia.

Emerge holds three backends: Wayland, DRM, and macOS. **This plan uses none of
them.** It uses the raster backend, which is `EmergeSkia.render_to_pixels/2`. That
function takes a tree and a size, and it gives the pixels back to the caller. It
opens no window and it touches no display.

    pixels = EmergeSkia.render_to_pixels(tree, otp_app: :my_hi_fi, width: 320, height: 240)

The result is RGBA8888, four bytes for each pixel, row by row. A 320 by 240 frame is
307 200 bytes.

The library ships the Inter font in the NIF, so a text element needs no font file.

### 2.1 What a measurement gave

A host with an x86_64 processor drew the tree below on 2026-08-26. The first frame
took 116 ms, and each frame after it took 0.84 ms. The first frame is slow because
Skia builds its font cache one time.

    column(
      [width(px(320)), height(px(240)), padding(12), spacing(8),
       Background.color(color(:slate, 900))],
      [
        el([Font.size(22), Font.color(color(:white))], text("Radio New Zealand")),
        el([Font.size(14), Font.color(color(:slate, 400))], text("National - 128 kbps AAC")),
        el([width(fill()), height(px(6)), Border.rounded(3),
            Background.color(color(:emerald, 500))], none())
      ]
    )

The board is much slower than that host, and **no measurement of the board exists**.
Section 9 holds this as the first risk.

## 3. Which NIF, and the one library that is missing

**No backend is what this firmware wants.** It never opens a window and it never
touches a DRM device. `backend/raster.rs` is not behind a Cargo feature, so a build
with no feature gives a raster-only NIF, and that NIF needs `libfontconfig`,
`libfreetype` and `libstdc++` only. Each of those is in the rootfs already.

**Emerge publishes no such artefact.** It publishes three variants for each target,
and each one carries a backend:

| `compiled_backends` | Precompiled artefact |
|---|---|
| `[:wayland]` | The plain `.so` |
| `[:drm]` | The `--drm` `.so` |
| `[:wayland, :drm]` | The `--drm_wayland` `.so` |
| `[]` | **None** |

`EmergeSkia.BuildConfig.precompiled_profile/3` gives `{:error, :unsupported_profile}`
for `[]`, and `rustler_precompiled` then builds from source. That was measured on
2026-08-26, and not read.

Each published variant names shared libraries, and the system holds most of them.

| Library | Plain | `--drm` | In `myhifi_rpi0_2` |
|---|---|---|---|
| `libc.so.6` (2.38 or later) | Needs | Needs | Yes, 2.43 |
| `libstdc++.so.6` | Needs | Needs | Yes |
| `libgcc_s.so.1` | Needs | Needs | Yes |
| `libfontconfig.so.1` | Needs | Needs | Yes |
| `libfreetype.so.6` | Needs | Needs | Yes |
| `libxkbcommon.so.0` | Needs | No | **No** |
| `libgbm.so.1` | No | Needs | **No** |

`libfontconfig` and `libfreetype` are in `rootfs.squashfs` already, and that was read
with `unsquashfs`. So the plain variant misses one small library, and the `--drm`
variant misses Mesa.

### 3.1 Three ways, and what each one costs

1. **`[:wayland]`, and add `BR2_PACKAGE_LIBXKBCOMMON=y` to the system.** One line in
   `nerves_system_myhifi_rpi0_2`. The firmware then holds Wayland code that never
   runs, and a library that nothing calls. The raster path needs no display server:
   a host with `DISPLAY`, `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` all removed drew
   the frame of section 2.1 without a fault.
2. **`[]`, and build the NIF from source.** This gives the correct binary, and it
   needs no change to the system at all. It needs a Rust toolchain for
   `aarch64-nerves-linux-gnu` and a Skia cross-compile. Skia publishes a binary for
   the common triples and none for this one, so each clean build compiles Skia. That
   is long, and it may not work at the first try.
3. **`[:drm]`, and add Mesa.** Emerge then drives the panel itself. The kernel holds
   no driver for an ILI9341, so this also needs `CONFIG_DRM_MIPI_DBI`,
   `CONFIG_TINYDRM_MI0283QT` and the `pitft28-resistive` overlay. It is the largest
   change, and it removes the SPI code of section 5 completely.

**This plan proposes 1**, because it is one line and it is certain. 2 is correct and
slow. 3 is where this may go later, and it is too much for a spike.

### 3.2 NBPR does not serve here

`CLAUDE.md` says to use NBPR when a later version needs another binary. **That rule
does not reach this case.** NBPR ships a library in the `priv` of a package, and
`NBPR.Application` prepends `LD_LIBRARY_PATH` at boot. Its own documentation says
that this is for "external programs spawned by the BEAM". glibc reads
`LD_LIBRARY_PATH` one time, when the process starts, so a change after that does not
move the search path of a later `dlopen`. A NIF of the BEAM therefore does not find
an NBPR library, and a program that a port starts does.

### 3.3 Ask Emerge for a variant with no backend

`precompiled_variants/2` of `EmergeSkia.BuildConfig` is a map, and a `raster` entry
would publish the binary that section 3 asks for. Emerge already reads
`NERVES_SDK_SYSROOT`, `MIX_TARGET` and the Nerves compiler prefixes, so it knows
about Nerves. Open an issue for this. It would remove the library of 3.1 and make
option 2 unnecessary.

## 4. `mix.exs` sets the wrong vendor for `rustler_precompiled`

`@bundlex_targets` sets `TARGET_VENDOR` to `"nerves"`. `RustlerPrecompiled` reads the
same four variables, and it then looks for a NIF for `aarch64-nerves-linux-gnu`.
Emerge publishes `aarch64-unknown-linux-gnu`, so the two do not agree, and
`rustler_precompiled` builds from source instead.

The documentation of `rustler_precompiled` says to set `TARGET_VENDOR` to `unknown`
on Nerves. Bundlex puts the value in a map and reads it nowhere else, and
`Membrane.PrecompiledDependencyProvider` matches the architecture, the operating
system and the ABI, and never the vendor. **The change is therefore safe: set
`TARGET_VENDOR` to `"unknown"`.**

`EmergeSkia.BuildConfig` also sees `MIX_TARGET` and chooses `[:drm]` by itself, so
`config/target.exs` must name the variant that section 3.1 chose.

## 5. The pixel path

    Emerge tree
      -> EmergeSkia.render_to_pixels/2   (RGBA8888, 307 200 bytes)
      -> RGB565, big endian              (153 600 bytes)
      -> ILI9341 over /dev/spidev0.0

The kernel holds `CONFIG_SPI_SPIDEV=y`, and `config.txt` holds `dtparam=spi=on`, so
`/dev/spidev0.0` and `/dev/spidev0.1` exist today. No change to the system is
necessary for the bus.

**A full frame at 32 MHz takes 38 ms.** That is 153 600 bytes, and it is more than
the time to draw the frame. The screen is therefore limited by the bus and not by
Skia. A `Player.Progress` event arrives one time each second, so this is ample.

Two things need care:

- **`spidev` accepts 4096 bytes in one transfer by default.** The driver takes
  `bufsiz` as a module parameter. Either `cmdline.txt` sets `spidev.bufsiz=65536`, or
  the driver writes the frame in parts. Parts need no change to the system, so the
  plan writes in parts. `Circuits.SPI.max_transfer_size/0` gives the limit, so the
  driver reads it and does not hold a constant.
- **A partial window costs less.** The ILI9341 takes a column range and a page range,
  so a change of the time only needs the rows that hold the time. The first version
  writes the whole frame, and a measurement says whether that is necessary.

The conversion from RGBA to RGB565 is a comprehension over a binary. A measurement on
the board says whether Elixir is fast enough for it, or whether it needs a NIF.

## 6. The modules

    MyHiFi.Peripheral                  # the behaviour of section 5.3 of the spec
    MyHiFi.Peripheral.Server           # the GenServer that wraps a peripheral
    MyHiFi.Peripheral.PiTft            # subscribes, holds the view state, draws
    MyHiFi.Peripheral.PiTft.Ili9341    # the SPI commands and the pixel writes
    MyHiFi.Peripheral.PiTft.Screen     # the Emerge tree for the now playing screen

`MyHiFi.Peripheral` and `MyHiFi.Peripheral.Server` come from section 5.3 of the
specification, and they do not change with this plan.

`MyHiFi.Peripheral.PiTft` subscribes to `:player` only. The `:view` and `:hint`
topics need `MyHiFi.DeviceUi`, and that does not exist. The screen therefore shows
the now playing view and nothing else, and the browse view comes with
`MyHiFi.DeviceUi`.

`MyHiFi.Peripheral.PiTft.Ili9341` uses `circuits_spi` and `circuits_gpio`. Both are
standard Nerves libraries.

`circuits_spi` gives no simulator of its own. `Circuits.SPI.NilBackend` is what a
host gets, and its `open/2` gives `{:error, :unimplemented}`, so it drives no test.
Both libraries read the backend from the application environment, so a test backend
in `test/support` that records each transfer is what proves the driver on the host.
That is the pattern that `:output` and `:sources` already use. `circuits_sim` is the
other option, and it holds no ILI9341 device, so it gives less.

## 7. The pins

The Adafruit board uses these. **Confirm each one on the clone before you write the
driver**, as section 5.3 of the specification says.

| Signal | Pin |
|---|---|
| Screen chip select | CE0, `/dev/spidev0.0` |
| Touch chip select | CE1, `/dev/spidev0.1` |
| Data or command | GPIO 25 |
| Backlight | GPIO 18 |
| Touch interrupt | GPIO 24 |

The board holds no reset line to the Pi on the later revisions. The I2C pins stay
free, which is what the knob needs.

## 8. `solve`, and why not now

See <https://hex.pm/packages/solve>. It models a user interface as a graph of state
machines, and it holds the state outside the render code. Emerge is its main
presentation layer.

**This plan does not use it.** Three reasons:

1. `MyHiFi.DeviceUi` already holds that place in section 5.4 of the specification,
   and the parts already talk through PubSub. `solve` would be a second way to hold
   the same state, and `CLAUDE.md` says one source of truth.
2. Its README says that the implementation "is very sloppy and will eventually be
   completely replaced", and that the module documentation is not written.
3. The screen must draw before any of this matters.

Look at it again when `MyHiFi.DeviceUi` is written and the web interface and the
screen need the same navigation state.

## 9. Risks and unknowns

| Risk | Why it matters | What answers it |
|---|---|---|
| The time to draw a frame on the board | The board is much slower than the host, and 0.84 ms could become 50 ms | Measure `render_to_pixels/2` on the board |
| The memory that Skia needs | 202 MB was available with audio in play, and Skia holds a font cache and a surface | Measure the BEAM and the system after 100 frames |
| The size of the firmware | The NIF is 18 MB, and the archive is 7 MB | Build and compare |
| The parts of the clone | The screen may not be an ILI9341 | Read the board |
| The speed of the SPI bus | 32 MHz is what the driver asks for, and the panel may not accept it | Draw a test pattern and look |
| RGBA to RGB565 in Elixir | 307 200 bytes for each frame | Measure, and write a NIF only if the measurement asks for it |
| One library in the system | Section 3.1 | A build of `nerves_system_myhifi_rpi0_2` |

## 10. Questions for James

1. **The system change of section 3.1.** Do you accept one line in
   `nerves_system_myhifi_rpi0_2`, and the build that follows it? Way 2 needs no
   system change and gives the correct binary, and each clean build then compiles
   Skia.
2. **The firmware grows by about 7 MB.** `CLAUDE.md` refused ffmpeg at 32 MB and
   portaudio at 17 MB. Is 7 MB acceptable for the screen?
3. **The scope of the spike.** Section 6 draws the now playing screen from the
   `:player` events, and it holds no touch and no `MyHiFi.DeviceUi`. Is that the
   slice that you want first?

## 11. Order of work

1. Set `TARGET_VENDOR` to `"unknown"` in `mix.exs`, and add `emerge`, `circuits_spi`
   and `circuits_gpio`. Set `compiled_backends` in `config/target.exs` to the choice
   of section 3.1.
2. Write `MyHiFi.Peripheral` and `MyHiFi.Peripheral.Server`, with tests.
3. Write `MyHiFi.Peripheral.PiTft.Screen`, and a test that draws it to a PNG on the
   host. A person then looks at the file.
4. Write `MyHiFi.Peripheral.PiTft.Ili9341` against the `:stub` backend of
   `circuits_spi`, with tests for the commands and the window.
5. Write `MyHiFi.Peripheral.PiTft`, and start it from `MyHiFi.Application` on the
   target only.
6. Add the library to `nerves_system_myhifi_rpi0_2`, and build it.
7. Measure the board: the time to draw, the time to write, and the memory.
8. Write the numbers into `docs/spec.md`, and name Emerge there.
