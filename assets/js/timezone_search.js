// Arrow keys move through the matches of the time zone search, Enter picks one and
// Escape closes the list. The server filters and the server saves, so this hook only
// tracks which row is highlighted: LiveView can't keep that between keystrokes without a
// round trip for each one.
//
// The highlight is `aria-selected` on the button, which the template styles, so a list
// that LiveView draws again after a keystroke simply loses it and the next arrow starts
// from the top. Enter with nothing highlighted falls through to the form, which saves
// whatever name a person typed in full.
export const TimezoneSearch = {
  mounted() {
    this.input = this.el.querySelector("input")
    this.list = this.el.querySelector("[role=listbox]")
    this.input.addEventListener("keydown", (event) => this.key(event))
  },

  key(event) {
    const options = Array.from(this.list.querySelectorAll("button"))
    const current = options.findIndex((option) => option.ariaSelected === "true")

    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        this.open()
        this.highlight(options, Math.min(current + 1, options.length - 1))
        break

      case "ArrowUp":
        event.preventDefault()
        this.highlight(options, Math.max(current - 1, 0))
        break

      case "Enter":
        if (current >= 0) {
          event.preventDefault()
          options[current].click()
        }
        break

      case "Escape":
        this.js().hide(this.list)
        break

      default:
        this.open()
    }
  },

  open() {
    this.js().show(this.list)
  },

  highlight(options, index) {
    options.forEach((option, position) => {
      option.ariaSelected = position === index ? "true" : "false"
    })

    options[index]?.scrollIntoView({block: "nearest"})
  }
}
