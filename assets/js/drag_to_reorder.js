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
