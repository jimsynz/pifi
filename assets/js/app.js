// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import {accent} from "./accent"
import {cover} from "./cover"
import {DragToReorder} from "./drag_to_reorder"
import {Flash} from "./flash"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// **No fallback transport, because `PiFiWeb.Endpoint` serves none.** A window here
// would send the client to a transport that answers 404, and a socket that misses that
// window is one that Phoenix remembers: it writes `phx:fallback:LongPoll` to
// `sessionStorage` and skips the websocket for the rest of the session. A device that
// answers a library of thousands of albums is busy for a moment now and then, and it
// must not lose its socket for that. With no fallback the client retries the websocket.
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {DragToReorder, Flash}
})

accent()
cover()

// The bar that runs across the top of the page while it loads.
//
// A flat block of one colour, and no blur under it, which is the rule that the rest
// of this interface follows. topbar draws a gradient of five colours with a shadow
// blurred by 10 pixels when nothing says otherwise, and that is the language this
// design replaced.
//
// **`barColors` names a stop of a gradient, so one stop is a flat fill.** The colour
// is the coral of the palette, which reads on the paper ground and on the dark one,
// and it is the one colour that this interface gives to nothing else at rest.
//
// `shadowBlur` is 0 because a blur is what a hard shadow is not. topbar offsets its
// shadow by nothing, so a shadow of 0 blur would sit exactly behind the bar and show
// no edge at all: the colour is therefore transparent, and the bar is the whole mark.
topbar.config({
  barThickness: 6,
  barColors: {0: "#ff6b6b"},
  shadowBlur: 0,
  shadowColor: "rgba(0, 0, 0, 0)"
})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
