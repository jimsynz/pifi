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
export function cover() {
  window.addEventListener(
    "error",
    (event) => {
      const target = event.target

      if (target instanceof HTMLImageElement && target.dataset.cover !== undefined) {
        target.remove()
      }
    },
    true
  )
}
