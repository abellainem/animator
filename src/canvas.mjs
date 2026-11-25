// The canvas animation loop. The renderer is kept out of Lustre's virtual DOM:
// Gleam computes the full curve of every path once (whenever the code or
// `shape_slider` changes) and pushes it here via `setDrawing`. A single
// requestAnimationFrame loop owns the clock and, each frame, reveals a growing
// prefix of the precomputed points straight to the 2D context. So per frame
// there is no geometry work and no vdom diffing — just canvas strokes — which
// is what lets many paths animate at high frames per second.
//
// Values cross the Gleam/JS boundary directly — no JSON: a Gleam record arrives
// as an object with named fields, and a Gleam list is iterable.


let canvas = null;
let ctx = null;
// { paths: [{ pts: Float64Array [x0,y0,...], thickness, color, fill, closed,
//              start, end }], endClock, anyClosed, anyOwnFill }
let drawing = null;
let rate = 1; // a multiple of normal speed; negative plays the drawing backward
let clock = 0; // the drawing's time, in tenths of a second, in [0, endClock]
let lastTs = 0;
let running = false;
let framesWithoutCanvas = 0;
// Called once each time the clock reaches the end of the drawing (see onFinish).
let finishListener = null;
let finished = false;
// Coloring mode: the fill colour ("" when off), and how far the fill has swept
// in, from 0 (none) to 1 (every closed shape filled). The fill only advances
// once every outline has finished drawing. Paths can also carry a fill colour
// of their own (from colored/filled in the code), which fills whether or not
// coloring mode is on; coloring mode's colour fills the closed shapes that
// have none.
let fillColor = "";
let fillProgress = 0;
// The fill-speed slider's multiple of normal fill speed. It is separate from
// the speed slider, which only sets the fill's direction (backward drains it,
// paused pauses it).
let fillSpeed = 1;
// How long a completed fill has been showing, in seconds, before the drawing
// counts as finished (and, outside coloring mode, starts over).
let fillHold = 0;
// Click-to-recolor: fill colours the user picked for single shapes, by their
// index in the drawing. They beat both a path's own fill and coloring mode's
// colour, and only show in coloring mode.
let recolors = new Map();
// Called with a shape's index when the user clicks it to recolor it.
let recolorListener = null;
// Called with true when shapes become clickable (coloring mode, fill done)
// and false when they stop being clickable.
let recolorReadyListener = null;
let recolorReady = false;
// When true, fills are hidden and only outlines are drawn, in the colours
// they would otherwise have. Recolors and the fill's progress are kept.
let outlineOnly = false;
// How long the fill takes to sweep in at normal fill speed, in seconds.
const FILL_SECONDS = 2;
// How long a filled drawing stays on screen before it repeats, in seconds.
const HOLD_SECONDS = 1;

const TENTHS_PER_SECOND = 10;
// How many frames (about 10 seconds' worth) to wait for the canvas to appear
// before reporting that it hasn't.
const MAX_FRAMES_WITHOUT_CANVAS = 600;

// Replace the drawing being animated. `pathList` is the List(RenderPath) built
// by render.gleam; each path's points are packed into a flat Float64Array so
// the per-frame draw loop touches only contiguous numbers.
export function setDrawing(pathList) {
  const paths = [];
  for (const p of pathList) {
    const flat = [];
    for (const q of p.points) flat.push(q.x, q.y);
    const pts = new Float64Array(flat);
    paths.push({
      pts,
      thickness: p.thickness,
      color: p.color,
      fill: p.fill,
      // True when the path set its outline colour in code (colored/outlined).
      ownColor: Boolean(p.own_color),
      closed: isClosed(pts),
      start: p.start,
      end: p.end,
    });
  }
  // Keep the current clock across drawing swaps: dragging the shape slider on an
  // already-finished drawing shows the new shape complete, rather than restarting.
  // `endClock` is the moment the last path finishes drawing, past which the frame
  // loop holds time still (see frame).
  drawing = {
    paths,
    endClock: drawingEndClock(paths),
    anyClosed: paths.some((p) => p.closed),
    anyOwnFill: paths.some((p) => p.closed && p.fill),
  };
  if (!running) {
    running = true;
    lastTs = performance.now();
    requestAnimationFrame(frame);
  }
}

// The clock at which every path has fully drawn — the largest per-path finish
// time (u = 1). A path finishes at its `end` time, or right at `start` when it
// has no positive duration (end ≤ start, an instant path). An empty drawing
// has nothing to finish, so time runs on unbounded (Infinity).
function drawingEndClock(paths) {
  let end = Infinity;
  for (const p of paths) {
    const finish = Math.max(p.start, p.end);
    end = end === Infinity ? finish : Math.max(end, finish);
  }
  return end;
}

// Register `callback` to run each time the animation finishes: the frame in
// which the clock first reaches the moment the last path is fully drawn.
export function onFinish(callback) {
  finishListener = callback;
}

export function setSpeed(r) {
  rate = r;
}

// Set how fast fills sweep in, as a multiple of normal. Takes effect at once,
// even partway through a fill.
export function setFillSpeed(r) {
  fillSpeed = r > 0 ? r : 0;
}

// Jump the animation back to the start (empty canvas).
export function resetClock() {
  clock = 0;
  fillProgress = 0;
  fillHold = 0;
}

// Replace the per-shape fill colours with `entries`, a Gleam list of
// #(index, colour) tuples (each a two-element array here).
export function setRecolors(entries) {
  recolors = new Map();
  for (const [index, color] of entries) recolors.set(index, color);
}

// Show only outlines (true) or fills and outlines (false). Does not restart
// the drawing or forget recolors.
export function setOutlineOnly(on) {
  outlineOnly = !!on;
}

// Register `callback` to run with a shape's index when the user clicks a
// closed shape in coloring mode after the fill has finished.
export function onRecolor(callback) {
  recolorListener = callback;
}

// Register `callback` to run with true when recoloring becomes available and
// false when it stops being available.
export function onRecolorReady(callback) {
  recolorReadyListener = callback;
}

// Whether clicking a shape recolors it right now: coloring mode is on and the
// outlines and the fill have both finished.
function canRecolor() {
  return (
    drawing !== null &&
    fillColor !== "" &&
    drawing.anyClosed &&
    drawing.endClock !== Infinity &&
    clock >= drawing.endClock &&
    fillProgress >= 1
  );
}

// The index of the topmost closed shape under a mouse event on the canvas (the
// one drawn last wins), or -1. Hit-testing uses the same transform as render,
// mapping the event from CSS pixels to the canvas's backing-store pixels, and
// the points already include the size slider's scaling.
function shapeAt(event) {
  if (!canvas || !ctx || !drawing) return -1;
  const rect = canvas.getBoundingClientRect();
  if (rect.width === 0 || rect.height === 0) return -1;
  const x = ((event.clientX - rect.left) * canvas.width) / rect.width;
  const y = ((event.clientY - rect.top) * canvas.height) / rect.height;
  ctx.save();
  ctx.setTransform(canvas.width / 1000, 0, 0, canvas.height / 1000, canvas.width / 2, canvas.height / 2);
  let hit = -1;
  for (let i = drawing.paths.length - 1; i >= 0 && hit < 0; i--) {
    const p = drawing.paths[i];
    if (!p.closed) continue;
    if (ctx.isPointInPath(outlinePath(p.pts), x, y)) hit = i;
  }
  ctx.restore();
  return hit;
}

// A closed Path2D through a path's points, in world coordinates.
function outlinePath(pts) {
  const path = new Path2D();
  path.moveTo(pts[0], pts[1]);
  for (let i = 2; i < pts.length; i += 2) path.lineTo(pts[i], pts[i + 1]);
  path.closePath();
  return path;
}

// Clicks and the pointer cursor are handled on the document, because Lustre
// can replace the canvas element (e.g. after an error is fixed).
if (typeof document !== "undefined") {
  document.addEventListener("click", (event) => {
    if (event.target.id !== "animation-canvas" || !canRecolor()) return;
    const index = shapeAt(event);
    if (index >= 0 && recolorListener) recolorListener(index);
  });
  document.addEventListener("mousemove", (event) => {
    if (event.target.id !== "animation-canvas") return;
    event.target.style.cursor = canRecolor() && shapeAt(event) >= 0 ? "pointer" : "";
  });
}

// Whether the current drawing has anything to fill once its outlines finish.
function hasFill() {
  return drawing.anyOwnFill || (fillColor !== "" && drawing.anyClosed);
}

// Turn coloring mode on with a CSS colour, or off with "".
export function setFill(color) {
  fillColor = color;
  if (!color) fillProgress = 0;
}

function frame(ts) {
  // Cap dt so a backgrounded/paused tab can't jump the clock far ahead.
  const dt = Math.min((ts - lastTs) / 1000, 0.1);
  lastTs = ts;
  // The clock runs forward, each path drawing in over its window and then
  // staying; there is no loop back to an empty canvas. It is bounded at both
  // ends: reverse rewinds only as far as the start (0), and forward stops the
  // instant the last path has fully drawn (endClock), so time never runs on past
  // a finished drawing.
  // In coloring mode, once the outlines are done the fill sweeps in, and time
  // holds at the end while it does. Played backward, the fill drains first and
  // then the outlines rewind.
  const atEnd = clock >= drawing.endClock && drawing.endClock !== Infinity;
  const filling = hasFill();
  if (filling && atEnd && (rate > 0 || fillProgress > 0)) {
    const direction = Math.sign(rate);
    fillProgress = clamp(
      fillProgress + (dt * direction * fillSpeed) / FILL_SECONDS,
      0,
      1,
    );
    fillHold = fillProgress >= 1 && rate > 0 ? fillHold + dt : 0;
  } else {
    clock += dt * rate * TENTHS_PER_SECOND;
    clock = clamp(clock, 0, drawing.endClock);
  }
  render();
  // Report the moment the drawing becomes complete (once, not every frame it
  // stays complete), after drawing that complete frame.
  // A drawing with fills isn't finished until they have swept in and shown
  // for a moment.
  const nowFinished =
    rate > 0 &&
    clock >= drawing.endClock &&
    (!filling || (fillProgress >= 1 && fillHold >= HOLD_SECONDS));
  if (nowFinished && !finished && finishListener) finishListener();
  finished = nowFinished;
  // Tell the app when recoloring becomes available or stops being available.
  const ready = canRecolor();
  if (ready !== recolorReady) {
    recolorReady = ready;
    if (!ready && canvas) canvas.style.cursor = "";
    if (recolorReadyListener) recolorReadyListener(ready);
  }
  requestAnimationFrame(frame);
}

// Match the backing store to the element's CSS size (× device pixel ratio) so
// the drawing stays crisp; only touched when the size actually changes.
function ensureSize() {
  const dpr = window.devicePixelRatio || 1;
  const w = Math.round(canvas.clientWidth * dpr);
  const h = Math.round(canvas.clientHeight * dpr);
  if (w > 0 && h > 0 && (canvas.width !== w || canvas.height !== h)) {
    canvas.width = w;
    canvas.height = h;
  }
}

// Find the page's canvas, which Lustre can add to the page after the first drawing
// arrives. Returns whether it is there.
function findCanvas() {
  const el = document.getElementById("animation-canvas");
  if (!el) {
    framesWithoutCanvas += 1;
    if (framesWithoutCanvas === MAX_FRAMES_WITHOUT_CANVAS) {
      console.error('The page has no <canvas id="animation-canvas"> element to draw on.');
    }
    return false;
  }
  if (el !== canvas) {
    canvas = el;
    ctx = canvas.getContext("2d");
  }
  return true;
}

function render() {
  if (!findCanvas()) return;
  ensureSize();
  const w = canvas.width;
  const h = canvas.height;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, w, h);
  // Draw functions work in a 0..1000 world centred on the origin: scale it to
  // fill the canvas and translate (0, 0) to the middle, so positive coordinates
  // run toward the bottom-right corner.
  ctx.setTransform(w / 1000, 0, 0, h / 1000, w / 2, h / 2);
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  // Fills go under the outlines, so the outlines stay crisp on top.
  if (fillProgress > 0 && !outlineOnly) {
    for (let i = 0; i < drawing.paths.length; i++) {
      const p = drawing.paths[i];
      const color = fillOf(p, i);
      if (color) fillSweep(p, color);
    }
  }
  for (let i = 0; i < drawing.paths.length; i++) {
    const p = drawing.paths[i];
    // Each path is revealed by a parameter u ∈ [0, 1] that advances at a steady
    // rate. A path is complete once u reaches 1.
    const u = penU(p);
    // `u` clamps to 0 both before a path starts and at the very instant it
    // does, so it can't tell "not yet" from "just begun". Gate on the start
    // time instead, so a just-begun path is shown at rest at u = 0
    // rather than staying hidden until the clock advances.
    if (clock >= p.start) {
      drawUpToU(p, u, strokeOf(p, i));
    }
  }
}

// The fill colour a closed shape would use: a click-recolor in coloring mode,
// else the colour from the code, else coloring mode's picker colour.
function fillOf(p, i) {
  if (!p.closed) return "";
  if (fillColor && recolors.has(i)) return recolors.get(i);
  return p.fill || fillColor || "";
}

// The user-picked colour that should also be the outline, or "". In coloring
// mode that's a click-recolor, or the picker colour for a shape that has no
// fill and no outline of its own in the code. colored()/outlined() outlines
// stay as written unless the shape is click-recolored.
function pickedOf(p, i) {
  if (!p.closed || !fillColor) return "";
  if (recolors.has(i)) return recolors.get(i);
  if (!p.fill && !p.ownColor) return fillColor;
  return "";
}

// Outline colour: the picked colour once this shape's fill has started
// (fillProgress > 0), and at once for a click-recolor after the fill has
// finished. Lines, and code-specified outlines that haven't been recolored,
// keep p.color.
function strokeOf(p, i) {
  const picked = pickedOf(p, i);
  if (picked && fillProgress > 0) return picked;
  return p.color;
}

// How much of a path is revealed now: its parameter u ∈ [0, 1], advancing
// linearly from its start time to its end time — 0 before it starts, 1 once
// done. A path with no positive duration (end ≤ start) appears complete the
// moment it starts.
function penU(p) {
  const duration = p.end - p.start;
  if (duration <= 0) return clock >= p.start ? 1 : 0;
  const u = (clock - p.start) / duration;
  return u < 0 ? 0 : u > 1 ? 1 : u;
}

// Whether a path is a closed shape that can be filled: at least a triangle
// (4 points with the first repeated at the end) that ends where it starts,
// like a Polygon or a Circle.
function isClosed(pts) {
  const n = pts.length;
  // Allow a tiny gap: a circle's last point comes from sin(2π), which is
  // almost but not exactly 0.
  return (
    n >= 8 &&
    Math.abs(pts[0] - pts[n - 2]) < 1e-6 &&
    Math.abs(pts[1] - pts[n - 1]) < 1e-6
  );
}

// Fill a closed path with `color` up to the current fill progress, sweeping up
// from the bottom of the shape like paint poured in.
function fillSweep(p, color) {
  const pts = p.pts;
  let minY = Infinity;
  let maxY = -Infinity;
  for (let i = 1; i < pts.length; i += 2) {
    if (pts[i] < minY) minY = pts[i];
    if (pts[i] > maxY) maxY = pts[i];
  }
  // y grows downward, so the fill line rises from maxY toward minY.
  const top = maxY - (maxY - minY) * fillProgress;
  ctx.save();
  ctx.beginPath();
  ctx.rect(-1e6, top, 2e6, maxY - top + 1);
  ctx.clip();
  ctx.beginPath();
  ctx.moveTo(pts[0], pts[1]);
  for (let i = 2; i < pts.length; i += 2) ctx.lineTo(pts[i], pts[i + 1]);
  ctx.closePath();
  ctx.fillStyle = color;
  ctx.fill();
  ctx.restore();
}

function clamp(x, lo, hi) {
  return x < lo ? lo : x > hi ? hi : x;
}

// Stroke the first `u` fraction of a path's polyline, interpolating the final
// partial segment so the curve reveals smoothly rather than a vertex at a time.
function drawUpToU(p, u, color) {
  const pts = p.pts;
  const count = pts.length / 2;
  if (count < 2) return;
  const segs = count - 1;
  const f = u * segs;
  const k = Math.min(segs, Math.floor(f));
  ctx.beginPath();
  ctx.moveTo(pts[0], pts[1]);
  for (let i = 1; i <= k; i++) ctx.lineTo(pts[2 * i], pts[2 * i + 1]);
  const frac = f - k;
  if (k < segs && frac > 0) {
    const ax = pts[2 * k];
    const ay = pts[2 * k + 1];
    const bx = pts[2 * k + 2];
    const by = pts[2 * k + 3];
    ctx.lineTo(ax + (bx - ax) * frac, ay + (by - ay) * frac);
  }
  ctx.lineWidth = p.thickness;
  ctx.strokeStyle = color;
  ctx.stroke();
}

