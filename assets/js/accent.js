// The accent colour of the interface comes from the artwork that plays.
//
// The device reads the picture, because the device screen needs the same colour
// and no browser is open when a person is in the room alone. The server sends
// the answer with the track, and this sets it. See `MyHiFi.Artwork.Accent`.

const DEFAULT_ACCENT = "oklch(0.78 0.15 74)"

const set = (accent) =>
  document.documentElement.style.setProperty("--color-accent", accent || DEFAULT_ACCENT)

export const accent = () =>
  window.addEventListener("phx:accent", (event) => set(event.detail.colour))
