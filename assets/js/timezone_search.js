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
