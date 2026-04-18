/**
 * VisualCanvas — LiveView hook for animated workflow execution visualization.
 *
 * Renders trace events as glowing particles with trails, ripples, and
 * flow connections on a Canvas overlay. Events replay sequentially,
 * creating a "musical score" effect.
 */

const TOOL_COLORS = {
  Read: "#26B5A0",
  Write: "#F2A516",
  Edit: "#F2C744",
  Bash: "#5940D9",
  Grep: "#8b7cf7",
  Glob: "#7c6dd8",
  Agent: "#cc6666",
  TaskCreate: "#f0c674",
  TaskUpdate: "#f0c674",
  TodoWrite: "#f0c674",
  Search: "#00eefc",
  WebFetch: "#00eefc",
  ToolSearch: "#00eefc",
  default: "#e8e4df",
};

const PHASE_COLORS = {
  team: "#F2A516",
  session: "#F2A516",
  sprint: "#F2A516",
  "review-gate": "#26B5A0",
  evaluate: "#26B5A0",
  "pr-shepherd": "#F2C744",
  preflight: "#7c6dd8",
  scout: "#7c6dd8",
  api: "#8b7cf7",
};

function getColor(tool, isError) {
  if (isError) return "#ff725e";
  return TOOL_COLORS[tool] || TOOL_COLORS.default;
}

export default {
  mounted() {
    this.canvas = this.el.querySelector("canvas");
    if (!this.canvas) {
      console.warn("[VisualCanvas] No canvas element found");
      return;
    }

    this.ctx = this.canvas.getContext("2d");

    // Parse event data
    try {
      this.data = JSON.parse(this.el.dataset.events || "{}");
    } catch (e) {
      console.warn("[VisualCanvas] Failed to parse events:", e);
      this.data = { phases: [], events: [], total: 0 };
    }

    console.log("[VisualCanvas] Loaded", this.data.total, "events,", (this.data.phases || []).length, "phases");

    // Must resize first, then layout events (layout depends on width)
    this._resize();
    this._start();

    this._resizeHandler = () => {
      this._resize();
      this.layoutEvents = this._layoutEvents();
    };
    window.addEventListener("resize", this._resizeHandler);

    // Handle replay from server
    this.handleEvent("visual:replay", () => {
      this._start();
    });
  },

  destroyed() {
    if (this.animFrame) cancelAnimationFrame(this.animFrame);
    if (this._resizeHandler) window.removeEventListener("resize", this._resizeHandler);
  },

  _resize() {
    const container = this.canvas.parentElement;
    const rect = container.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;

    // Use container width, calculate height from phases
    const phaseCount = Math.max((this.data.phases || []).length, 1);
    const LANE_H = 70;
    const PAD = 60;

    this.width = Math.max(rect.width - 32, 400); // subtract padding
    this.height = phaseCount * LANE_H + PAD;

    this.canvas.width = this.width * dpr;
    this.canvas.height = this.height * dpr;
    this.canvas.style.width = this.width + "px";
    this.canvas.style.height = this.height + "px";
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  },

  _layoutEvents() {
    const events = this.data.events || [];
    const phases = this.data.phases || [];
    if (events.length === 0 || this.width <= 0) return [];

    const LANE_H = 70;
    const TOP = 30;
    const PAD_X = 30;
    const usableWidth = this.width - PAD_X * 2;

    return events.map((ev, i) => {
      const phaseIdx = ev.phase || 0;
      const y = TOP + phaseIdx * LANE_H + LANE_H / 2;
      const x = PAD_X + (i / Math.max(events.length - 1, 1)) * usableWidth;

      return {
        x, y,
        tool: ev.tool,
        isError: ev.error,
        phase: phaseIdx,
        phaseType: phases[phaseIdx]?.type || "session",
      };
    });
  },

  _start() {
    if (this.animFrame) cancelAnimationFrame(this.animFrame);

    this.particles = [];
    this.ripples = [];
    this.settled = [];
    this.spawnIndex = 0;
    this.startTime = performance.now();
    this.layoutEvents = this._layoutEvents();

    console.log("[VisualCanvas] Starting animation with", this.layoutEvents.length, "events, canvas:", this.width, "x", this.height);

    if (this.layoutEvents.length > 0) {
      this._tick();
    } else {
      // No events — draw empty phase lanes
      this._drawLanes();
    }
  },

  _tick() {
    const ctx = this.ctx;
    const now = performance.now();
    const elapsed = now - this.startTime;
    const events = this.layoutEvents;

    // Replay speed: all events over 5 seconds
    const DURATION = Math.max(events.length * 15, 3000);
    const spawnUpTo = Math.min(events.length, Math.floor((elapsed / DURATION) * events.length));

    // Spawn new particles
    while (this.spawnIndex < spawnUpTo) {
      const ev = events[this.spawnIndex];
      const color = getColor(ev.tool, ev.isError);

      this.particles.push({
        x: -10, y: ev.y + (Math.random() - 0.5) * 12,
        tx: ev.x, ty: ev.y,
        color, r: ev.isError ? 4.5 : 2 + Math.random() * 2,
        alpha: 1, birth: now, life: 3500 + Math.random() * 2000,
        isError: ev.isError, phase: ev.phase,
        trail: [],
      });

      this.ripples.push({
        x: ev.x, y: ev.y,
        radius: 0, maxR: ev.isError ? 22 : 14,
        color, birth: now + 300,
      });

      this.spawnIndex++;
    }

    // Clear
    ctx.clearRect(0, 0, this.width, this.height);

    // Phase lanes
    this._drawLanes();

    // Connections between settled particles
    ctx.globalCompositeOperation = "lighter";
    for (let i = 1; i < this.settled.length; i++) {
      const a = this.settled[i - 1];
      const b = this.settled[i];
      if (a.phase === b.phase) {
        ctx.beginPath();
        ctx.moveTo(a.x, a.y);
        ctx.quadraticCurveTo((a.x + b.x) / 2, (a.y + b.y) / 2 - 10, b.x, b.y);
        ctx.strokeStyle = b.color;
        ctx.globalAlpha = 0.06;
        ctx.lineWidth = 0.8;
        ctx.stroke();
      }
    }
    ctx.globalCompositeOperation = "source-over";

    // Particles
    const alive = [];
    for (const p of this.particles) {
      const age = now - p.birth;
      if (age > p.life) {
        this.settled.push({ x: p.tx, y: p.ty, color: p.color, phase: p.phase });
        continue;
      }

      // Fly to target
      const t = Math.min(age / 400, 1);
      const ease = 1 - Math.pow(1 - t, 3);
      p.x = -10 + (p.tx + 10) * ease;
      p.y += (p.ty - p.y) * 0.08;

      // Fade in last 40%
      const lr = age / p.life;
      p.alpha = lr > 0.6 ? 1 - (lr - 0.6) / 0.4 : 1;

      // Trail
      if (t < 1) {
        p.trail.push({ x: p.x, y: p.y, a: p.alpha * 0.4 });
        if (p.trail.length > 14) p.trail.shift();
      }

      // Draw trail
      for (let i = 0; i < p.trail.length; i++) {
        const tp = p.trail[i];
        ctx.beginPath();
        ctx.arc(tp.x, tp.y, 1, 0, Math.PI * 2);
        ctx.fillStyle = p.color;
        ctx.globalAlpha = tp.a * (i / p.trail.length) * 0.5;
        ctx.fill();
      }

      // Glow
      ctx.globalAlpha = p.alpha * 0.15;
      ctx.beginPath();
      ctx.arc(p.x, p.y, p.r * 4, 0, Math.PI * 2);
      ctx.fillStyle = p.color;
      ctx.fill();

      // Dot
      ctx.globalAlpha = p.alpha * 0.95;
      ctx.beginPath();
      ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
      ctx.fillStyle = p.color;
      ctx.fill();

      // Error ring
      if (p.isError) {
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.r + 5, 0, Math.PI * 2);
        ctx.strokeStyle = "#ff725e";
        ctx.globalAlpha = p.alpha * 0.4;
        ctx.lineWidth = 1.5;
        ctx.stroke();
      }

      alive.push(p);
    }
    this.particles = alive;

    // Ripples
    const aliveR = [];
    for (const r of this.ripples) {
      if (now < r.birth) { aliveR.push(r); continue; }
      const age = now - r.birth;
      const prog = age / 700;
      if (prog > 1) continue;

      ctx.beginPath();
      ctx.arc(r.x, r.y, r.maxR * prog, 0, Math.PI * 2);
      ctx.strokeStyle = r.color;
      ctx.globalAlpha = 0.35 * (1 - prog);
      ctx.lineWidth = 1.5;
      ctx.stroke();

      aliveR.push(r);
    }
    this.ripples = aliveR;

    // Settled dots
    for (const s of this.settled) {
      ctx.beginPath();
      ctx.arc(s.x, s.y, 1.8, 0, Math.PI * 2);
      ctx.fillStyle = s.color;
      ctx.globalAlpha = 0.35;
      ctx.fill();
    }

    ctx.globalAlpha = 1;

    if (alive.length > 0 || aliveR.length > 0 || this.spawnIndex < events.length) {
      this.animFrame = requestAnimationFrame(() => this._tick());
    } else {
      // Ambient breathing loop
      this._ambient();
    }
  },

  _drawLanes() {
    const ctx = this.ctx;
    const phases = this.data.phases || [];
    const LANE_H = 70;
    const TOP = 30;

    phases.forEach((phase, i) => {
      const y = TOP + i * LANE_H;
      const color = PHASE_COLORS[phase.type] || "#8b7cf7";

      // Lane bg
      ctx.fillStyle = color;
      ctx.globalAlpha = 0.04;
      ctx.fillRect(0, y, this.width, LANE_H - 6);

      // Left accent
      ctx.globalAlpha = 0.6;
      ctx.fillRect(0, y, 3, LANE_H - 6);

      // Label
      ctx.globalAlpha = 0.5;
      ctx.fillStyle = color;
      ctx.font = "600 11px 'Space Grotesk', sans-serif";
      ctx.fillText((phase.name || "").toUpperCase(), 12, y + 18);

      // Type
      ctx.globalAlpha = 0.25;
      ctx.fillStyle = "#777575";
      ctx.font = "400 9px 'Inter', sans-serif";
      ctx.fillText(phase.type || "", 12, y + 30);

      ctx.globalAlpha = 1;
    });
  },

  _ambient() {
    const ctx = this.ctx;

    const draw = () => {
      const t = performance.now() * 0.001;
      const breathe = 0.25 + 0.12 * Math.sin(t);

      ctx.clearRect(0, 0, this.width, this.height);
      this._drawLanes();

      // Connections
      ctx.globalCompositeOperation = "lighter";
      for (let i = 1; i < this.settled.length; i++) {
        const a = this.settled[i - 1];
        const b = this.settled[i];
        if (a.phase === b.phase) {
          ctx.beginPath();
          ctx.moveTo(a.x, a.y);
          ctx.quadraticCurveTo((a.x + b.x) / 2, (a.y + b.y) / 2 - 6, b.x, b.y);
          ctx.strokeStyle = b.color;
          ctx.globalAlpha = 0.04;
          ctx.lineWidth = 0.5;
          ctx.stroke();
        }
      }
      ctx.globalCompositeOperation = "source-over";

      // Dots with breathing glow
      for (const s of this.settled) {
        // Glow
        ctx.beginPath();
        ctx.arc(s.x, s.y, 5, 0, Math.PI * 2);
        ctx.fillStyle = s.color;
        ctx.globalAlpha = breathe * 0.06;
        ctx.fill();

        // Dot
        ctx.beginPath();
        ctx.arc(s.x, s.y, 1.8, 0, Math.PI * 2);
        ctx.fillStyle = s.color;
        ctx.globalAlpha = breathe + 0.15;
        ctx.fill();
      }

      ctx.globalAlpha = 1;
      this.animFrame = requestAnimationFrame(draw);
    };

    draw();
  },
};
