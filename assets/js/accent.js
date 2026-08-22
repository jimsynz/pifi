// The accent colour of the interface comes from the artwork that plays.
//
// The browser already holds the logo, so the browser reads it. The device
// decodes no image for this, and it needs no image library.
//
// The colour must stay readable on a near-black faceplate. The hook therefore
// works in OKLCH: it groups the pixels by hue, it takes the group with the most
// colour, and it clamps the lightness and the chroma of the result.

const SAMPLE_SIZE = 32
const HUE_BUCKETS = 24
const MIN_WEIGHT = 0.35
const LIGHTNESS = [0.72, 0.84]
const CHROMA = [0.08, 0.19]

const DEFAULT_ACCENT = "oklch(0.78 0.15 74)"

const toLinear = (value) => {
  const channel = value / 255
  return channel <= 0.04045 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
}

const toOklab = (red, green, blue) => {
  const r = toLinear(red)
  const g = toLinear(green)
  const b = toLinear(blue)

  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)

  return {
    lightness: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
  }
}

const clamp = ([low, high], value) => Math.min(high, Math.max(low, value))

const pixelsOf = (image) => {
  const canvas = document.createElement("canvas")
  canvas.width = SAMPLE_SIZE
  canvas.height = SAMPLE_SIZE

  const context = canvas.getContext("2d", {willReadFrequently: true})
  if (!context) return null

  context.drawImage(image, 0, 0, SAMPLE_SIZE, SAMPLE_SIZE)
  return context.getImageData(0, 0, SAMPLE_SIZE, SAMPLE_SIZE).data
}

const accentOf = (image) => {
  let pixels

  // A logo of another origin taints the canvas, and the read then throws. Every
  // logo comes from this device, so this guards against a change of the policy
  // and nothing else.
  try {
    pixels = pixelsOf(image)
  } catch (_error) {
    return null
  }

  if (!pixels) return null

  const buckets = new Array(HUE_BUCKETS).fill(null).map(() => ({weight: 0, a: 0, b: 0, lightness: 0}))

  for (let index = 0; index < pixels.length; index += 4) {
    if (pixels[index + 3] < 128) continue

    const colour = toOklab(pixels[index], pixels[index + 1], pixels[index + 2])
    if (colour.lightness < 0.12 || colour.lightness > 0.95) continue

    const chroma = Math.hypot(colour.a, colour.b)
    const hue = (Math.atan2(colour.b, colour.a) * 180) / Math.PI
    const bucket = buckets[Math.floor((((hue % 360) + 360) % 360) / (360 / HUE_BUCKETS))]
    const weight = chroma * chroma

    bucket.weight += weight
    bucket.a += colour.a * weight
    bucket.b += colour.b * weight
    bucket.lightness += colour.lightness * weight
  }

  const best = buckets.reduce((winner, bucket) => (bucket.weight > winner.weight ? bucket : winner))

  // A grey logo gives no accent, so the interface keeps the one it has.
  if (best.weight < MIN_WEIGHT) return null

  const a = best.a / best.weight
  const b = best.b / best.weight
  const hue = (((Math.atan2(b, a) * 180) / Math.PI) % 360 + 360) % 360

  const lightness = clamp(LIGHTNESS, best.lightness / best.weight)
  const chroma = clamp(CHROMA, Math.hypot(a, b))

  return `oklch(${lightness.toFixed(3)} ${chroma.toFixed(3)} ${hue.toFixed(1)})`
}

const apply = (image) => {
  const accent = accentOf(image)
  if (accent) document.documentElement.style.setProperty("--color-accent", accent)
}

const read = (image) => {
  if (image.complete && image.naturalWidth > 0) {
    apply(image)
  } else {
    image.addEventListener("load", () => apply(image), {once: true})
  }
}

export const Accent = {
  mounted() {
    read(this.el)
  },

  updated() {
    read(this.el)
  },

  destroyed() {
    document.documentElement.style.setProperty("--color-accent", DEFAULT_ACCENT)
  }
}
