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
