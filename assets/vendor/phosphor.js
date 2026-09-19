const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

// Phosphor Bold, as `ph-<name>`.
//
// **Every mark of this interface holds one weight, and Heroicons does not give one.**
// The solid set of Heroicons fills a gear and leaves a magnifying glass as a thin
// ring, and beside a border of 3 pixels that difference is the thing that a person
// sees first. Phosphor draws one stroke across the whole set.
//
// A file is named `<name>-bold.svg`, and the class drops that suffix: the bold weight
// is the only one that this project reads, so a name that carried it would say the
// same word on every line.
//
module.exports = plugin(function ({matchComponents, theme}) {
  let iconsDir = path.join(__dirname, "../../deps/phosphor_icons/assets/bold")
  let values = {}

  fs.readdirSync(iconsDir).forEach((file) => {
    let name = path.basename(file, ".svg").replace(/-bold$/, "")
    values[name] = {name, fullPath: path.join(iconsDir, file)}
  })

  let rules = ({name, fullPath}) => {
    let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
    content = encodeURIComponent(content)

    return {
      [`--ph-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
      "-webkit-mask": `var(--ph-${name})`,
      "mask": `var(--ph-${name})`,
      "mask-repeat": "no-repeat",
      "background-color": "currentColor",
      "vertical-align": "middle",
      "display": "inline-block",
      "width": theme("spacing.6"),
      "height": theme("spacing.6")
    }
  }

  matchComponents({ph: rules}, {values})
})
