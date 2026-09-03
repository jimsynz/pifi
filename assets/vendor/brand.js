// The mark of a service that this firmware reads, such as Jellyfin.
//
// It works in the way that `heroicons.js` works, and for the same reason: the mark
// becomes the mask of a span, and the colour comes from `currentColor`. A source icon
// therefore takes the accent colour of the interface, and one white logo does not sit
// on a panel in a colour of its own.
//
// Each file of `brand/` gives one class. `brand/jellyfin.svg` gives `brand-jellyfin`,
// and `MyHiFiWeb.CoreComponents` names that class for the `:jellyfin` icon.
//
// **The marks belong to the projects that made them, and each one carries its licence
// in a comment of its own file.** The Jellyfin icon is CC-BY-SA-4.0, which is not the
// licence of this repository. A comment survives a move of the file, and a person who
// adds a mark here must add the same.
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
      // The comment that carries the licence is for a person who opens the file, and
      // the browser needs none of it. Without this the whole of it reaches the style
      // sheet, encoded one character at a time.
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
        // **A mask holds the size of its own picture until something says otherwise.**
        // The icons of `heroicons.js` are 24 by 24, which is the size of the span, so
        // they fit and that plugin needs no rule here. A mark comes from the project
        // that made it and it holds any size: the Jellyfin mark is 72 by 72, so a span
        // of 20 showed the top left corner of it, which is nearly empty. A person saw
        // a sliver beside the name.
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
