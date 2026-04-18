/**
 * ForceGraph — Vanilla JS force-directed graph for the Memory Vault knowledge graph.
 * Receives graph data via data-graph attribute (JSON: {nodes: [...], edges: [...]}).
 * Runs a simple spring-force simulation and renders SVG.
 * Clicks on nodes push "select_note" events to the LiveView.
 */

const TYPE_COLORS = {
  decision: "#fbbf24",
  lesson: "#60a5fa",
  observation: "#2dd4bf",
  project: "#fb923c",
  tension: "#ef4444",
  moc: "#fde68a",
  handoff: "#7a8fa8",
  codebase: "#e879f9",
  other: "#94a3b8",
}

const ForceGraph = {
  mounted() {
    this.renderGraph()
  },

  updated() {
    // phx-update="ignore" prevents this, but safety net
  },

  renderGraph() {
    const raw = this.el.dataset.graph
    if (!raw) {
      this.el.innerHTML = '<div class="flex items-center justify-center h-full text-base-content/50 text-sm">No graph data</div>'
      return
    }

    let data
    try {
      data = JSON.parse(raw)
    } catch {
      this.el.innerHTML = '<div class="flex items-center justify-center h-full text-error text-sm">Invalid graph data</div>'
      return
    }

    if (!data.nodes || data.nodes.length === 0) {
      this.el.innerHTML = '<div class="flex items-center justify-center h-full text-base-content/50 text-sm">No notes with links found</div>'
      return
    }

    const width = this.el.clientWidth || 800
    const height = this.el.clientHeight || 500

    // Initialize positions
    const nodes = data.nodes.map((n) => ({
      ...n,
      x: width / 2 + (Math.random() - 0.5) * width * 0.5,
      y: height / 2 + (Math.random() - 0.5) * height * 0.5,
      vx: 0,
      vy: 0,
    }))

    const nodeMap = new Map(nodes.map((n) => [n.id, n]))
    const edges = data.edges.filter((e) => nodeMap.has(e.source) && nodeMap.has(e.target))

    // Run force simulation (100 iterations)
    this.simulate(nodes, edges, nodeMap, width, height, 100)

    // Render SVG
    this.renderSVG(nodes, edges, nodeMap, width, height)
  },

  simulate(nodes, edges, nodeMap, width, height, iterations) {
    const kRepel = 3000
    const kAttract = 0.005
    const kCenter = 0.01
    const damping = 0.85
    const maxForce = 10

    for (let iter = 0; iter < iterations; iter++) {
      // Repulsion between all pairs
      for (let i = 0; i < nodes.length; i++) {
        for (let j = i + 1; j < nodes.length; j++) {
          const a = nodes[i], b = nodes[j]
          let dx = b.x - a.x, dy = b.y - a.y
          const dist = Math.max(Math.sqrt(dx * dx + dy * dy), 1)
          const force = Math.min(kRepel / (dist * dist), maxForce)
          const fx = (dx / dist) * force, fy = (dy / dist) * force
          a.vx -= fx; a.vy -= fy
          b.vx += fx; b.vy += fy
        }
      }

      // Attraction along edges
      for (const e of edges) {
        const a = nodeMap.get(e.source), b = nodeMap.get(e.target)
        if (!a || !b) continue
        const dx = b.x - a.x, dy = b.y - a.y
        const dist = Math.sqrt(dx * dx + dy * dy)
        const force = kAttract * dist
        const fx = (dx / dist) * force, fy = (dy / dist) * force
        a.vx += fx; a.vy += fy
        b.vx -= fx; b.vy -= fy
      }

      // Center gravity
      const cx = width / 2, cy = height / 2
      for (const n of nodes) {
        n.vx += (cx - n.x) * kCenter
        n.vy += (cy - n.y) * kCenter
      }

      // Apply velocity with damping
      for (const n of nodes) {
        n.vx *= damping; n.vy *= damping
        n.x += n.vx; n.y += n.vy
        // Clamp to bounds
        n.x = Math.max(20, Math.min(width - 20, n.x))
        n.y = Math.max(20, Math.min(height - 20, n.y))
      }
    }
  },

  renderSVG(nodes, edges, nodeMap, width, height) {
    const ns = "http://www.w3.org/2000/svg"
    const svg = document.createElementNS(ns, "svg")
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
    svg.setAttribute("class", "w-full h-full")
    svg.style.cursor = "default"

    // Resolve theme-aware colors via CSS custom properties
    const edgeColor = getComputedStyle(this.el).getPropertyValue("--color-base-content").trim()
    const edgeStroke = edgeColor ? `oklch(${edgeColor} / 0.15)` : "rgba(150,150,150,0.15)"
    const labelFill = edgeColor ? `oklch(${edgeColor} / 0.55)` : "rgba(150,150,150,0.55)"

    // Draw edges
    for (const e of edges) {
      const a = nodeMap.get(e.source), b = nodeMap.get(e.target)
      if (!a || !b) continue
      const line = document.createElementNS(ns, "line")
      line.setAttribute("x1", a.x); line.setAttribute("y1", a.y)
      line.setAttribute("x2", b.x); line.setAttribute("y2", b.y)
      line.style.stroke = edgeStroke
      line.setAttribute("stroke-width", "1")
      svg.appendChild(line)
    }

    // Draw nodes
    const hook = this
    for (const n of nodes) {
      const color = TYPE_COLORS[n.type] || TYPE_COLORS.other
      // Scale node size by connection count
      const degree = edges.filter(e => e.source === n.id || e.target === n.id).length
      const r = Math.max(4, Math.min(12, 4 + degree * 1.5))

      const circle = document.createElementNS(ns, "circle")
      circle.setAttribute("cx", n.x); circle.setAttribute("cy", n.y)
      circle.setAttribute("r", r)
      circle.setAttribute("fill", color)
      circle.setAttribute("opacity", "0.85")
      circle.style.cursor = "pointer"

      // Hover effect
      circle.addEventListener("mouseenter", () => {
        circle.setAttribute("r", r + 3)
        circle.setAttribute("opacity", "1")
      })
      circle.addEventListener("mouseleave", () => {
        circle.setAttribute("r", r)
        circle.setAttribute("opacity", "0.85")
      })
      circle.addEventListener("click", () => {
        // Use path field if available (TS dashboard graph), fall back to id (local graph)
        hook.pushEvent("select_note", { path: n.path || n.id })
      })
      svg.appendChild(circle)

      // Label
      if (nodes.length < 100) {
        const text = document.createElementNS(ns, "text")
        text.setAttribute("x", n.x); text.setAttribute("y", n.y - r - 3)
        text.setAttribute("text-anchor", "middle")
        text.setAttribute("font-size", nodes.length < 50 ? "9" : "7")
        text.style.fill = labelFill
        text.style.pointerEvents = "none"
        text.textContent = n.label.length > 24 ? n.label.slice(0, 22) + "…" : n.label
        svg.appendChild(text)
      }
    }

    // Legend
    const legendTypes = [...new Set(nodes.map(n => n.type))]
    if (legendTypes.length > 0) {
      const legendG = document.createElementNS(ns, "g")
      legendG.setAttribute("transform", `translate(12, ${height - legendTypes.length * 16 - 8})`)
      legendTypes.forEach((type, i) => {
        const c = document.createElementNS(ns, "circle")
        c.setAttribute("cx", "6"); c.setAttribute("cy", i * 16 + 6)
        c.setAttribute("r", "4")
        c.setAttribute("fill", TYPE_COLORS[type] || TYPE_COLORS.other)
        legendG.appendChild(c)
        const t = document.createElementNS(ns, "text")
        t.setAttribute("x", "16"); t.setAttribute("y", i * 16 + 10)
        t.setAttribute("font-size", "9")
        t.style.fill = labelFill
        t.textContent = type
        legendG.appendChild(t)
      })
      svg.appendChild(legendG)
    }

    this.el.innerHTML = ""
    this.el.appendChild(svg)
  },

  destroyed() {
    this.el.innerHTML = ""
  },
}

export default ForceGraph
