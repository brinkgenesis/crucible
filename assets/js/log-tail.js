// LogTail hook — auto-scrolls a log container to bottom on updates.
// Unpins when user scrolls up; re-pins when user scrolls back to bottom.
const LogTail = {
  mounted() {
    this.pinned = true
    this.el.scrollTop = this.el.scrollHeight
    this.el.addEventListener("scroll", () => {
      const threshold = 30
      const atBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < threshold
      this.pinned = atBottom
    })
    this.handleEvent("scroll-bottom", () => {
      this.pinned = true
      this.el.scrollTop = this.el.scrollHeight
    })
  },

  updated() {
    if (this.pinned) {
      this.el.scrollTop = this.el.scrollHeight
    }
  }
}

export default LogTail
