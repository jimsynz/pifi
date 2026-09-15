// A picture that the cache does not hold answers 404, and a browser then draws its own
// mark for a broken picture. That mark is worse than the folder behind it, so this takes
// the image away and lets the folder show.
//
// **A listener and not an `onerror` attribute.** The content security policy of
// `MyHiFiWeb.Router` names no `script-src`, so it takes the `default-src` of `'self'`,
// and an attribute of that kind is inline script. It never ran.
//
// The listener captures, because the `error` of an image does not bubble. One listener
// serves every list and every patch of LiveView, so a row that arrives later needs
// nothing of its own.
//
// **A 404 is often a picture that has not arrived yet.** A page asks for the pictures of
// the list that it draws, and the job that reads one needs a moment.
// `MyHiFiWeb.Shell` sends `artwork-ready` for each thumbnail that arrives, so this waits
// for the word of the device and asks for that address alone. Two timers asked three
// times for every picture that a page missed, and a page of a library misses 25 of them.
//
// The address carries a mark of the moment, because a browser holds the answer that it
// got for the address alone.
const waiting = new Map()

export function cover() {
  window.addEventListener(
    "error",
    (event) => {
      const target = event.target

      if (target instanceof HTMLImageElement && target.dataset.cover !== undefined) {
        hold(target)
      }
    },
    true
  )

  window.addEventListener("phx:artwork-ready", (event) => {
    show(event.detail.path)
  })
}

// The image goes, and this keeps the place that it came from. LiveView draws the row
// again for each event of the player, and the image that it draws then asks once more,
// so a picture that arrives while the page is closed to this event still appears.
function hold(image) {
  const path = address(image)
  const parent = image.parentNode

  image.remove()

  if (!parent) return

  const places = waiting.get(path) || []

  waiting.set(path, places.concat([{ image, parent }]))
}

function show(path) {
  const places = waiting.get(path)

  waiting.delete(path)

  if (!places) return

  for (const { image, parent } of places) {
    if (!parent.isConnected || parent.contains(image)) continue

    image.src = `${path}?ready=${Date.now()}`
    parent.appendChild(image)
  }
}

function address(image) {
  return new URL(image.src, window.location.origin).pathname
}
