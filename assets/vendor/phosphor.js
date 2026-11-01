const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

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
