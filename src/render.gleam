//// Convert each shape into a list of points called a RenderPath.

import gleam/int
import gleam/list
import shape.{type Path, type Point, Circle, Line, Point, Polygon}

/// How many straight segments approximate a circle.
const circle_segments = 72

@external(javascript, "./math_ffi.mjs", "sin")
fn sin(x: Float) -> Float

@external(javascript, "./math_ffi.mjs", "cos")
fn cos(x: Float) -> Float

@external(javascript, "./math_ffi.mjs", "pi")
fn pi() -> Float

/// One path as canvas.mjs setDrawing consumes it (field by field): the
/// polyline, stroke colour/width, fill colour ("" for none of its own), and the
/// start and end times (in tenths of a second)
/// between which the reveal runs — so the renderer's clock needs no shape
/// knowledge.
pub type RenderPath {
  RenderPath(
    points: List(Point),
    thickness: Float,
    color: String,
    fill: String,
    start: Float,
    end: Float,
    // True when the path set its outline colour in the code (colored/outlined).
    own_color: Bool,
  )
}

// ── The canvas (canvas.mjs) ───────────────────────────────────────────────────

/// Replace the drawing being animated in the page's
/// `<canvas id="animation-canvas">` element. If that element doesn't appear within
/// about 10 seconds, this logs an error to the browser console. This keeps the
/// current time, so a drawing that replaces a finished one appears complete. To
/// animate it from the start, also call reset_clock.
@external(javascript, "./canvas.mjs", "setDrawing")
pub fn set_drawing(paths: List(RenderPath)) -> Nil

/// Set the animation's speed, as a multiple of its normal speed: 1.0 is normal and
/// is where it starts, 0.0 pauses, and a negative rate plays it backward.
/// Time stops at the start of the drawing and when its last path finishes, so
/// playing a finished drawing again takes a call to reset_clock.
@external(javascript, "./canvas.mjs", "setSpeed")
pub fn set_speed(rate: Float) -> Nil

/// Jump the animation back to its start, where the canvas is empty.
@external(javascript, "./canvas.mjs", "resetClock")
pub fn reset_clock() -> Nil

/// Turn coloring mode's fill on with a CSS colour, or off with "". While it's on,
/// every closed shape without a fill of its own fills with this colour once the
/// outlines are drawn. Fills given in code happen whether or not it's on.
@external(javascript, "./canvas.mjs", "setFill")
pub fn set_fill(color: String) -> Nil

/// How fast fills sweep in, as a multiple of normal (1.0 takes 2 seconds). It
/// takes effect immediately, even partway through a fill.
@external(javascript, "./canvas.mjs", "setFillSpeed")
pub fn set_fill_speed(rate: Float) -> Nil

/// Show only outlines (True) or fills and outlines (False). Does not restart
/// the drawing or forget recolors.
@external(javascript, "./canvas.mjs", "setOutlineOnly")
pub fn set_outline_only(on: Bool) -> Nil

/// Replace the fill colours the user picked for single shapes: each entry is a
/// shape's index in the drawing and its CSS colour. They beat a path's own fill
/// and coloring mode's colour, and only show while coloring mode is on.
@external(javascript, "./canvas.mjs", "setRecolors")
pub fn set_recolors(entries: List(#(Int, String))) -> Nil

/// Ask the canvas to call `callback` with a shape's index when the user clicks
/// a closed shape in coloring mode, once the fill has finished.
@external(javascript, "./canvas.mjs", "onRecolor")
pub fn on_recolor(callback: fn(Int) -> Nil) -> Nil

/// Ask the canvas to call `callback` with True when shapes become clickable for
/// recoloring and False when they stop being clickable.
@external(javascript, "./canvas.mjs", "onRecolorReady")
pub fn on_recolor_ready(callback: fn(Bool) -> Nil) -> Nil

/// The RenderPath for a path, outlined in its own colour or else in `color`.
pub fn render_path(path: Path, color: String) -> RenderPath {
  let points = case path.shape {
    Line(a, b) -> [a, b]
    Polygon(points) -> close(points)
    Circle(center, radius) -> circle_points(center, radius, 0)
  }
  let outline = case path.color {
    "" -> color
    own -> own
  }
  RenderPath(
    points,
    path.thickness,
    outline,
    path.fill,
    path.start,
    path.end,
    path.color != "",
  )
}

// A polygon's outline: its points, then back to the first to close it.
fn close(points: List(Point)) -> List(Point) {
  case points {
    [first, ..] -> list.append(points, [first])
    [] -> []
  }
}

// The circle_segments + 1 points around a circle, from angle 0 (the rightmost
// point) all the way back to it. y grows downward, so this runs clockwise.
fn circle_points(center: Point, radius: Float, i: Int) -> List(Point) {
  case i > circle_segments {
    True -> []
    False -> {
      let angle =
        2.0 *. pi() *. int.to_float(i) /. int.to_float(circle_segments)
      [
        Point(
          center.x +. radius *. cos(angle),
          center.y +. radius *. sin(angle),
        ),
        ..circle_points(center, radius, i + 1)
      ]
    }
  }
}
