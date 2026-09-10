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
// the list that it draws, and the job that reads one needs a moment. The page draws no
// picture in that moment, and the answer it holds does not change again, so the image
// asks two more times before it goes. The address carries the count of the attempt,
// because a browser holds the answer that it got for the address alone.
const RETRY_DELAYS_MS = [2000, 5000]

export function cover() {
  window.addEventListener(
    "error",
    (event) => {
      const target = event.target

      if (target instanceof HTMLImageElement && target.dataset.cover !== undefined) {
        retry(target)
      }
    },
    true
  )
}

function retry(image) {
  const attempt = Number(image.dataset.coverAttempt || 0)
  const delay = RETRY_DELAYS_MS[attempt]
  const parent = image.parentNode
  const address = image.src.split("?")[0]

  image.remove()

  if (delay === undefined || !parent) return

  setTimeout(() => {
    if (!parent.isConnected) return

    image.dataset.coverAttempt = attempt + 1
    image.src = `${address}?attempt=${attempt + 1}`
    parent.appendChild(image)
  }, delay)
}
