const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = plugin(function({matchComponents, theme}) {
  let brandDir = path.join(__dirname, "brand")
  let values = {}
  fs.readdirSync(brandDir).filter(file => file.endsWith(".svg")).forEach(file => {
    let name = path.basename(file, ".svg")
    values[name] = {name, fullPath: path.join(brandDir, file)}
  })
  matchComponents({
    "brand": ({name, fullPath}) => {
      let content = fs.readFileSync(fullPath).toString()
        .replace(/<!--[\s\S]*?-->/g, "")
        .replace(/\r?\n|\r/g, "")
        .trim()
      content = encodeURIComponent(content)
      let size = theme("spacing.6")
      return {
        [`--brand-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
        "-webkit-mask": `var(--brand-${name})`,
        "mask": `var(--brand-${name})`,
        "mask-repeat": "no-repeat",
        "mask-size": "contain",
        "mask-position": "center",
        "background-color": "currentColor",
        "vertical-align": "middle",
        "display": "inline-block",
        "width": size,
        "height": size
      }
    }
  }, {values})
})
