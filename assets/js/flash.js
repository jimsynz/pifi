const REMOVE_AFTER_MS = 5000

export const Flash = {
  mounted() {
    this.startPeriod()
  },

  updated() {
    this.startPeriod()
  },

  destroyed() {
    clearTimeout(this.timer)
  },

  startPeriod() {
    clearTimeout(this.timer)

    this.timer = setTimeout(
      () => this.js().exec(this.el.getAttribute("phx-click")),
      REMOVE_AFTER_MS
    )
  }
}
