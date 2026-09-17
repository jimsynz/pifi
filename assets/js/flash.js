// A notice says what the device did, and then it must go by itself. This device is a
// stereo component on a shelf, and a person who walks past it does not press a notice
// away. A notice that stays also covers the interface behind it.
//
// The client holds the time, because a notice is a piece of the interface and the
// server keeps no timer for one. The hook runs the command that the notice already
// holds, so `PiFiWeb.CoreComponents.flash/1` says one time how to remove a notice.
// `updated` starts the time again, so a second notice in the same place gets the full
// period.
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
