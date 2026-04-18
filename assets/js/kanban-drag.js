import Sortable from "../vendor/sortable.esm.js"

const KanbanDrag = {
  mounted() {
    this.initSortables()
  },

  updated() {
    this.initSortables()
  },

  initSortables() {
    // Destroy existing instances to avoid duplicates on re-render
    if (this._sortables) {
      this._sortables.forEach(s => s.destroy())
    }
    this._sortables = []

    this.el.querySelectorAll("[data-column]").forEach(col => {
      const s = Sortable.create(col, {
        group: "kanban",
        animation: 150,
        handle: ".drag-handle",
        ghostClass: "opacity-30",
        chosenClass: "shadow-lg",
        dragClass: "rotate-2",
        fallbackOnBody: true,
        swapThreshold: 0.65,
        onEnd: (evt) => {
          const cardId = evt.item.dataset.cardId
          const fromColumn = evt.from.dataset.column
          const toColumn = evt.to.dataset.column

          // Only push event if the column actually changed
          if (cardId && toColumn && fromColumn !== toColumn) {
            this.pushEvent("move_card", { id: cardId, column: toColumn })
          }
        }
      })
      this._sortables.push(s)
    })
  },

  destroyed() {
    if (this._sortables) {
      this._sortables.forEach(s => s.destroy())
    }
  }
}

export default KanbanDrag
