// TerminalScroll: auto-scrolls terminal output container to bottom on updates
const TerminalScroll = {
  mounted() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => this.scrollToBottom())
    this.observer.observe(this.el, { childList: true, subtree: true, characterData: true })
  },

  updated() {
    this.scrollToBottom()
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
  },

  scrollToBottom() {
    requestAnimationFrame(() => {
      this.el.scrollTop = this.el.scrollHeight
    })
  }
}

export default TerminalScroll
