# The originals of the product marks

These are the pictures that the marks of the products come from. Nothing at run
time reads them: `PiFi.Device.Identity.shipped_splash/1` reads
`priv/splash/<product>-<width>x<height>.png`, and each of those is already the
size of the screen that draws it.

**They live here and not in `priv/splash`, because everything under `priv` goes
into the firmware.** The two files hold 1.06 MB together, and a device that
cannot draw them would carry them on a card that holds the music. The test
`each picture that ships is the size that its name claims` reads that directory
and measures every PNG in it, so a file of another size stops the suite as well.

A new screen needs a file in `priv/splash` of the size of that screen. Scale it
from the picture here.
