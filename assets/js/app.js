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
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/crucible"
import KanbanDrag from "./kanban-drag"
import LogTail from "./log-tail"
import TerminalScroll from "./terminal-scroll"
import ForceGraph from "./force-graph"
import topbar from "../vendor/topbar"

// Download hook: triggers a file download from push_event data
const Download = {
  mounted() {
    this.handleEvent("download", ({content, filename, content_type}) => {
      const blob = new Blob([content], {type: content_type})
      const url = URL.createObjectURL(blob)
      const a = document.createElement("a")
      a.href = url
      a.download = filename
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      URL.revokeObjectURL(url)
    })
  }
}

// CopyToClipboard hook: copies text to clipboard on click
const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.clipboardText
      if (text) {
        navigator.clipboard.writeText(text).then(() => {
          const original = this.el.innerHTML
          this.el.innerHTML = '<span class="text-success text-xs">Copied!</span>'
          setTimeout(() => { this.el.innerHTML = original }, 1500)
        })
      }
    })
  }
}

// MobileSidebar hook: toggle sidebar on mobile, auto-close on navigation
const MobileSidebar = {
  mounted() {
    const sidebar = this.el
    const overlay = document.getElementById("sidebar-overlay")
    const toggle = document.getElementById("sidebar-toggle")

    this.open = () => {
      sidebar.classList.remove("hidden")
      sidebar.classList.add("flex")
      overlay?.classList.remove("hidden")
      toggle?.setAttribute("aria-expanded", "true")
    }

    this.close = () => {
      if (window.innerWidth >= 768) return
      sidebar.classList.add("hidden")
      sidebar.classList.remove("flex")
      overlay?.classList.add("hidden")
      toggle?.setAttribute("aria-expanded", "false")
    }

    this.toggleHandler = () => {
      if (sidebar.classList.contains("hidden")) {
        this.open()
      } else {
        this.close()
      }
    }

    window.addEventListener("toggle-sidebar", this.toggleHandler)

    // Close on LiveView navigation
    window.addEventListener("phx:page-loading-start", () => this.close())
  },

  destroyed() {
    window.removeEventListener("toggle-sidebar", this.toggleHandler)
  }
}

const EXECUTION_MODE_KEY = "infra:executionMode"

function normalizeExecutionMode(mode) {
  if (mode === "api") return "api"
  if (mode === "sdk") return "sdk"
  return "subscription"
}

function readExecutionMode() {
  return normalizeExecutionMode(localStorage.getItem(EXECUTION_MODE_KEY))
}

function broadcastExecutionMode(mode) {
  window.dispatchEvent(
    new CustomEvent("infra:execution-mode-changed", {detail: {mode: normalizeExecutionMode(mode)}}),
  )
}

const ExecutionModeToggle = {
  mounted() {
    this.buttons = Array.from(this.el.querySelectorAll("[data-execution-mode]"))
    this.clickHandlers = []

    this.applyMode = (mode) => {
      const activeMode = normalizeExecutionMode(mode)
      this.buttons.forEach((button) => {
        const active = button.dataset.executionMode === activeMode
        button.dataset.active = active ? "true" : "false"
        button.setAttribute("aria-pressed", active ? "true" : "false")
      })
    }

    this.persistMode = (mode) => {
      const activeMode = normalizeExecutionMode(mode)
      localStorage.setItem(EXECUTION_MODE_KEY, activeMode)
      this.applyMode(activeMode)
      broadcastExecutionMode(activeMode)
    }

    this.buttons.forEach((button) => {
      const handler = (event) => {
        event.preventDefault()
        this.persistMode(button.dataset.executionMode)
      }

      button.addEventListener("click", handler)
      this.clickHandlers.push({button, handler})
    })

    this.executionModeListener = (event) => {
      this.applyMode(event.detail?.mode)
    }

    window.addEventListener("infra:execution-mode-changed", this.executionModeListener)
    this.applyMode(readExecutionMode())
  },

  destroyed() {
    this.clickHandlers?.forEach(({button, handler}) => button.removeEventListener("click", handler))

    if (this.executionModeListener) {
      window.removeEventListener("infra:execution-mode-changed", this.executionModeListener)
    }
  },
}

const ExecutionModeSync = {
  mounted() {
    this.pushMode = (mode) => this.pushEvent("set_execution_mode", {mode: normalizeExecutionMode(mode)})
    this.executionModeListener = (event) => this.pushMode(event.detail?.mode)

    window.addEventListener("infra:execution-mode-changed", this.executionModeListener)
    this.pushMode(readExecutionMode())
  },

  destroyed() {
    if (this.executionModeListener) {
      window.removeEventListener("infra:execution-mode-changed", this.executionModeListener)
    }
  },
}

import VisualCanvas from "./hooks/visual_canvas.js"

const hooks = {
  ...colocatedHooks,
  KanbanDrag,
  LogTail,
  TerminalScroll,
  ForceGraph,
  Download,
  CopyToClipboard,
  ExecutionModeToggle,
  ExecutionModeSync,
  MobileSidebar,
  VisualCanvas,
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
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
