//// Drawing a program: call its draw function on the shape slider's value and
//// convert the list it returns into the Paths the animator renders.
////
//// The user's integers become the Float fields the geometry needs.

import errors.{type EvalError, BadDrawing, PathLimit}
import evaluator.{type GlobalFrame, type Value, VData, VInt, VList}
import gleam/int
import gleam/list
import gleam/result
import limits
import shape.{
  type Path, type Point, type Shape, Circle, Line, Path, Point, Polygon,
}

/// Call the program's draw function on shape_slider, returning its list of
/// paths or the evaluation error, so the app can show failures.
pub fn try_draw(
  shape_slider: Int,
  global: GlobalFrame,
) -> Result(List(Path), EvalError) {
  case evaluator.run("draw", [VInt(shape_slider)], global) {
    Ok(VList(items)) ->
      // The step allowance bounds what evaluation can build, but the
      // renderer redraws every path each frame, so a finished drawing is
      // also capped.
      case list.length(items) > limits.path_limit {
        True -> Error(PathLimit)
        False -> list.try_map(items, to_path)
      }
    Ok(_) -> Error(BadDrawing("return value of draw is not a list"))
    Error(err) -> Error(err)
  }
}

fn to_path(v: Value) -> Result(Path, EvalError) {
  case v {
    VData("Path", [shape, VInt(start), VInt(end), VInt(thickness)]) -> {
      use s <- result.try(to_shape(shape))
      Ok(Path(
        s,
        int.to_float(start),
        int.to_float(end),
        int.to_float(thickness),
        "",
        "",
      ))
    }
    // A path with its own colours, from colored, filled, or outlined (see
    // builtins.gleam). Either colour can be NoColor, which keeps the default.
    VData("Colored", [inner, outline, fill]) -> {
      use path <- result.try(to_path(inner))
      use outline <- result.try(to_color(outline))
      use fill <- result.try(to_color(fill))
      Ok(Path(..path, color: outline, fill: fill))
    }
    _ -> Error(BadDrawing("some element is not a well-formed path"))
  }
}

/// An rgb(r, g, b) colour as the CSS "rgb(r, g, b)", or "" for NoColor. The
/// rgb built-in already checks its channels; this checks again so a drawing
/// can never hand the canvas a colour it can't read.
fn to_color(v: Value) -> Result(String, EvalError) {
  case v {
    VData("NoColor", []) -> Ok("")
    VData("Rgb", [VInt(r), VInt(g), VInt(b)]) ->
      case list.all([r, g, b], fn(c) { c >= 0 && c <= 255 }) {
        True ->
          Ok(
            "rgb("
            <> int.to_string(r)
            <> ", "
            <> int.to_string(g)
            <> ", "
            <> int.to_string(b)
            <> ")",
          )
        False -> Error(BadDrawing("a colour's channels must be from 0 to 255"))
      }
    _ -> Error(BadDrawing("a colour must be made with rgb(r, g, b)"))
  }
}

fn to_shape(v: Value) -> Result(Shape, EvalError) {
  case v {
    VData("Line", [start, end]) -> {
      use a <- result.try(to_point(start))
      use b <- result.try(to_point(end))
      Ok(Line(a, b))
    }
    VData("Polygon", [VList(items)]) -> {
      use points <- result.try(list.try_map(items, to_point))
      case points {
        [_, _, _, ..] -> Ok(Polygon(points))
        _ -> Error(BadDrawing("a Polygon needs at least 3 points"))
      }
    }
    VData("Polygon", _) ->
      Error(BadDrawing("a Polygon's points must be a list of Points"))
    VData("Circle", [center, VInt(radius)]) -> {
      use c <- result.try(to_point(center))
      case radius > 0 {
        True -> Ok(Circle(c, int.to_float(radius)))
        False -> Error(BadDrawing("a Circle's radius must be positive"))
      }
    }
    VData("Circle", _) ->
      Error(BadDrawing("a Circle needs a center Point and an Int radius"))
    _ -> Error(BadDrawing("a Path's shape must be a recognized shape"))
  }
}

fn to_point(v: Value) -> Result(Point, EvalError) {
  case v {
    VData("Point", [VInt(x), VInt(y)]) ->
      Ok(Point(int.to_float(x), int.to_float(y)))
    _ -> Error(BadDrawing("expected a Point"))
  }
}
