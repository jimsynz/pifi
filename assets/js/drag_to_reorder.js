// A person moves a row of the play queue by dragging it. A mouse drags it, and so does
// a finger.
//
// **Pointer events, and not the drag and drop of HTML.** That interface reaches no
// touch screen, and a phone is the interface that this device gets most of the time.
// One pointer covers the mouse, the finger and the pen.
//
// The hook moves the row in the page while the person drags it, so they read the new
// order as they make it. The server holds the order, so the drop sends one `move` and
// `PiFiWeb.QueueLive` draws the list again from `PiFi.Playback.Queue`.
//
// **The handle takes the pointer, and the list keeps the listener.** A capture sends
// every later event of that pointer to the handle, so a fast drag that leaves the row
// does not lose it, and a row that LiveView draws again needs no listener of its own.
export const DragToReorder = {
  mounted() {
    this.el.addEventListener("pointerdown", (event) => this.start(event))
    this.el.addEventListener("pointermove", (event) => this.moveTo(event))
    this.el.addEventListener("pointerup", (event) => this.drop(event))
    this.el.addEventListener("pointercancel", (event) => this.drop(event))
  },

  start(event) {
    const handle = event.target.closest("[data-drag-handle]")

    if (!handle || event.button > 0) return

    this.row = handle.closest("[data-row]")

    if (!this.row) return

    this.pointerId = event.pointerId
    this.startIndex = this.rows().indexOf(this.row)
    this.row.classList.add("opacity-60")
    handle.setPointerCapture(event.pointerId)
    event.preventDefault()
  },

  moveTo(event) {
    if (!this.row || event.pointerId !== this.pointerId) return

    const over = document
      .elementFromPoint(event.clientX, event.clientY)
      ?.closest("[data-row]")

    if (!over || over === this.row || !this.el.contains(over)) return

    const box = over.getBoundingClientRect()
    const after = event.clientY > box.top + box.height / 2

    this.el.insertBefore(this.row, after ? over.nextSibling : over)
  },

  drop(event) {
    if (!this.row || event.pointerId !== this.pointerId) return

    const row = this.row
    const position = this.rows().indexOf(row)

    this.row = null
    this.pointerId = null
    row.classList.remove("opacity-60")

    if (position !== this.startIndex) {
      this.pushEvent("move", {id: row.dataset.row, position: position})
    }
  },

  rows() {
    return Array.from(this.el.querySelectorAll("[data-row]"))
  }
}
