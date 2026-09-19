# The originals of the product marks

These are the pictures that the marks of the products come from. Nothing at run
time reads them: `PiFi.Device.Identity.shipped_splash/1` reads
`priv/splash/<product>-<width>x<height>.png`, and each of those is already the
size of the screen that draws it.

**They live here and not in `priv/splash`, because everything under `priv` goes
into the firmware.** A device that cannot draw a file would carry it on a card
that holds the music. The test `each picture that ships is the size that its
name claims` reads `priv/splash` and measures every PNG in it, so a file of
another size stops the suite as well.

A new screen needs a file in `priv/splash` of the size of that screen.

## The PiFi mark

`pifi-320x240.svg` and `pifi-240x240.svg` hold the lockup of the website, at the
size of each screen. The shapes come from `pifi-logo.svg` of the website
repository, inside one `transform` that fits them to the frame. A new size needs
a copy of one file and a new `transform`.

**Render at four times the size and scale the answer down:**

```sh
inkscape --export-type=png --export-filename=/tmp/big.png -w 1280 -h 960 pifi-320x240.svg
magick /tmp/big.png -resize 320x240 ../../priv/splash/pifi-320x240.png
```

**A render at the size of the screen shows the ground through the letters.** The
mark is built from rectangles that abut, and each group of black shapes carries a
`stroke` of one unit in its own fill colour to close the seam between two of
them. The `transform` of these files scales that stroke to about half a pixel,
which is too thin to cover the seam, and a hairline of cyan then runs through
every letter. Four times the size gives the stroke two pixels to work with, and
the scale down keeps the edges smooth.

## The PodBox mark

`podbox.png` is the original of `priv/splash/podbox-240x240.png` and
`podbox-320x240.png`. It is not drawn in the style of the website yet.
