//// Animator -- an application for program-generated drawings.

import builtins
import data
import drawing
import editor
import errors
import examples
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/attribute as attr
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import parser
import presets
import render
import shape.{type Path, Point}

/// Your app's public address, once you've deployed it in Problem 13, such as
/// "https://your-username.github.io/animator/".
pub const public_url = ""

/// Set to True if you would like your app's URL included in the course gallery.
pub const include_app_in_gallery = False

/// A link to your video from Problem 14, which anyone with the link can watch.
pub const video_url = ""

/// Set to True if you would like your video included in the course gallery.
pub const include_video_in_gallery = False

const default_code =
  "fn draw(shape_slider: Int) -> List(Path) {\n  [Path(Line(Point(0, 0), Point(100, 100)), 0, 10, 2)]\n}\n"

/// A new drawing starts from this: it parses and draws nothing, so the editor
/// is effectively blank and the canvas is empty, with no error to show.
const new_drawing_code = "fn draw(shape_slider: Int) -> List(Path) {\n  []\n}\n"

// ── Model ──────────────────────────────────────────────────────────────────────

pub type Model {
  Model(
    // The code in the editor.
    source: String,
    // Whether the code editor is shown.
    code_open: Bool,
    // The message to show in place of the animation when the code fails to
    // parse or evaluate, or None when the drawing is animating.
    error: Option(String),
    // The value passed to draw as its shape_slider argument, in [0, 100].
    shape_slider: Int,
    // The animation's speed as a multiple of normal speed (negative plays it
    // backward), as last sent to render.set_speed.
    speed: Float,
    // Every drawing in the menu, as #(name, source), in menu order.
    drawings: List(#(String, String)),
    // The name of the drawing shown in the editor.
    selected: String,
    // Whether coloring mode is on: the drawing traces once, stops repeating,
    // and then its closed shapes fill in with fill_color.
    coloring: Bool,
    // The fill colour, as "#rrggbb" from the colour picker.
    fill_color: String,
    // How fast fills sweep in, as a multiple of normal fill speed, as last
    // sent to render.set_fill_speed.
    fill_speed: Float,
    // The fill colours the user picked by clicking single shapes in coloring
    // mode: for each drawing, #(shape index, "#rrggbb") pairs. Saved under
    // their own localStorage key (see data.save_colors).
    recolors: List(#(String, List(#(Int, String)))),
    // Whether clicking a shape recolors it right now (coloring mode is on and
    // the fill has finished), as last reported by the canvas.
    recolor_ready: Bool,
    // For each drawing, its recolors as they were before each click or reset,
    // newest first, so undo can step back through them. Kept only for this
    // session, and forgotten when the drawing's code changes.
    undo: List(#(String, List(List(#(Int, String))))),
    // Up to palette_size colours most recently used to recolor a shape, as
    // "#rrggbb", newest first and without repeats. Saved under their own
    // localStorage key (see data.save_palette).
    palette: List(String),
    // When True, a click on a palette swatch is ignored. The native colour
    // picker sits over the palette; when it closes, the leftover click would
    // otherwise hit a swatch and overwrite the colour just picked.
    ignore_swatch: Bool,
    // Raised each time the colour picker fires, so an older "stop ignoring"
    // timeout cannot clear a newer one early.
    picker_token: Int,
    // When True, the canvas hides fills and shows only outlines.
    outline_only: Bool,
    // When True, show the on-page "name this drawing" field. Used when the
    // browser blocks window.prompt, so choosing "+ New drawing…" never
    // silently does nothing.
    naming: Bool,
    naming_text: String,
  )
}

pub type Msg {
  SetCode(String)

  // Layout controls
  ToggleCode

  // The animation's last path has finished drawing.
  AnimationFinished

  // Slider controls
  SetShapeSlider(Int)
  SetSpeed(Float)

  // Coloring mode
  ToggleColoring
  SetFillColor(String)
  SetFillSpeed(Float)

  // Click-to-recolor
  RecolorShape(Int)
  RecolorReady(Bool)
  ResetColors
  UndoColors

  // Palette
  PickSwatch(String)
  // The colour was chosen in the native <input type="color"> picker.
  SetFillColorFromPicker(String)
  AllowSwatches(Int)
  ToggleOutlineOnly

  // Drawing menu
  SelectDrawing(String)
  NewDrawingNamed(String)
  SetNamingText(String)
  ConfirmNewDrawing
  CancelNaming
}

/// The colour used to draw every path.
const path_color = "#cfe3ff"

/// Where the size slider starts: the middle, which draws at normal size.
const initial_shape_slider = 50

/// The size slider value that draws at normal size. The whole drawing scales
/// by shape_slider / normal_size around the centre of the canvas, so 0 is
/// tiny, 50 is normal, and 100 is twice as big.
const normal_size = 50.0

/// The smallest scale, so a drawing never shrinks to nothing at 0.
const min_scale = 0.05

/// The speed slider's range, as multiples of normal speed. Negative speeds play
/// the drawing backward.
const min_speed = -3.0

const max_speed = 3.0

/// The menu option's value that means "create a new drawing". It's the empty
/// string because Gradescope's tests treat every other option as a drawing.
const new_drawing_option = ""

/// Name used if examples.all is ever empty.
const fallback_name = "untitled"

/// Set the drawing menu back to the option for `name`, for when the user picks
/// "New drawing…" and then cancels.
@external(javascript, "./app_ffi.mjs", "setSelectValue")
fn set_select_value(test_id: String, name: String) -> Nil

@external(javascript, "./app_ffi.mjs", "focusSelector")
fn focus_selector(selector: String) -> Nil

/// Put the menu back on the open drawing, then ask for a name with the
/// assignment's prompt. Doing this in the change handler (not later, in an
/// effect) keeps it in the same user gesture, and resetting the menu first
/// means "+ New drawing…" can be chosen again even if the prompt is blocked.
fn ask_new_drawing_name(current: String) -> Msg {
  set_select_value("drawing-select", current)
  NewDrawingNamed(data.prompt_drawing_name())
}

/// Run callback after ms milliseconds.
@external(javascript, "./app_ffi.mjs", "after")
fn after(ms: Int, callback: fn() -> Nil) -> Nil

/// How many recently used colours the palette keeps.
const palette_size = 5

/// How long after the native colour picker changes to ignore a leftover click
/// on a palette swatch, in milliseconds.
const swatch_guard_ms = 500

/// The fill colour that coloring mode starts with.
const initial_fill_color = "#e8a33c"

/// The fill-speed slider's range, as multiples of normal fill speed (a 2-second
/// sweep): from a slow 8-second wash to a near-instant quarter second.
const min_fill_speed = 0.25

const max_fill_speed = 8.0

/// Ask canvas.mjs to call `callback` each time the animation finishes, so the
/// app can start it over.
@external(javascript, "./canvas.mjs", "onFinish")
fn on_finish(callback: fn() -> Nil) -> Nil

// ── Init ───────────────────────────────────────────────────────────────────────

pub fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  // Restore the saved library, or start with the examples if there isn't one.
  // Either way, add any preset drawing the library doesn't have yet, after
  // the drawings already there.
  let #(drawings, saved_name) = case data.load_library() {
    Ok(#(saved, name)) -> #(add_presets(saved), name)
    Error(Nil) ->
      case add_presets(examples.all) {
        [] -> #([#(fallback_name, default_code)], fallback_name)
        [#(name, _), ..] as all -> #(all, name)
      }
  }
  // Reopen the drawing that was open last time, or else the first one.
  let #(first_name, first_source) = case list.key_find(drawings, saved_name) {
    Ok(source) -> #(saved_name, source)
    Error(Nil) ->
      case drawings {
        [first, ..] -> first
        [] -> #(fallback_name, default_code)
      }
  }
  let recolors = data.load_colors()
  let first_colors = result.unwrap(list.key_find(recolors, first_name), [])
  #(
    Model(
      source: "",
      code_open: True,
      error: None,
      shape_slider: initial_shape_slider,
      // canvas.mjs starts at normal speed.
      speed: 1.0,
      drawings: drawings,
      selected: first_name,
      coloring: False,
      fill_color: initial_fill_color,
      // canvas.mjs starts at normal fill speed.
      fill_speed: 1.0,
      recolors: recolors,
      recolor_ready: False,
      undo: [],
      palette: data.load_palette(),
      ignore_swatch: False,
      picker_token: 0,
      outline_only: False,
      naming: False,
      naming_text: "",
    ),
    // Effects that happen automatically at the start go here.
    effect.batch([
      open_in_editor(first_source),
      // Repeat the animation each time it finishes.
      effect.from(fn(dispatch) {
        on_finish(fn() { dispatch(AnimationFinished) })
      }),
      // Clicking a shape in coloring mode, once it's filled, recolors it.
      effect.from(fn(dispatch) {
        render.set_recolors(first_colors)
        render.on_recolor(fn(index) { dispatch(RecolorShape(index)) })
        render.on_recolor_ready(fn(ready) { dispatch(RecolorReady(ready)) })
      }),
    ]),
  )
}

// The open drawing's recolors.
fn current_colors(model: Model) -> List(#(Int, String)) {
  colors_of(model, model.selected)
}

fn colors_of(model: Model, name: String) -> List(#(Int, String)) {
  result.unwrap(list.key_find(model.recolors, name), [])
}

// The model with the open drawing's recolors replaced by shapes, and the
// effect that saves them and shows them on the canvas.
fn set_current_colors(
  model: Model,
  shapes: List(#(Int, String)),
) -> #(Model, Effect(Msg)) {
  let recolors = case shapes {
    [] -> list.filter(model.recolors, fn(d) { d.0 != model.selected })
    _ -> list.key_set(model.recolors, model.selected, shapes)
  }
  #(
    Model(..model, recolors: recolors),
    effect.from(fn(_) {
      data.save_colors(recolors)
      render.set_recolors(shapes)
    }),
  )
}

// The open drawing's undo history, newest first.
fn current_undo(model: Model) -> List(List(#(Int, String))) {
  result.unwrap(list.key_find(model.undo, model.selected), [])
}

fn set_current_undo(
  model: Model,
  history: List(List(#(Int, String))),
) -> Model {
  let undo = case history {
    [] -> list.filter(model.undo, fn(d) { d.0 != model.selected })
    _ -> list.key_set(model.undo, model.selected, history)
  }
  Model(..model, undo: undo)
}

// Change the open drawing's recolors to shapes as one undoable step, saving
// what they were first. A change that changes nothing adds no step.
fn change_current_colors(
  model: Model,
  shapes: List(#(Int, String)),
) -> #(Model, Effect(Msg)) {
  let before = current_colors(model)
  case before == shapes {
    True -> #(model, effect.none())
    False ->
      set_current_undo(model, [before, ..current_undo(model)])
      |> set_current_colors(shapes)
  }
}

// Make color the picker's colour, and the default fill in coloring mode.
fn apply_fill_color(model: Model, color: String) -> #(Model, Effect(Msg)) {
  #(Model(..model, fill_color: color), case model.coloring {
    True -> effect.from(fn(_) { render.set_fill(color) })
    False -> effect.none()
  })
}

// Put color at the front of the palette (moving it there if it's already in
// it), keep the newest palette_size, and save the palette.
fn use_color(model: Model, color: String) -> #(Model, Effect(Msg)) {
  let palette =
    [color, ..list.filter(model.palette, fn(c) { c != color })]
    |> list.take(palette_size)
  #(
    Model(..model, palette: palette),
    effect.from(fn(_) { data.save_palette(palette) }),
  )
}

// Show a drawing's saved recolors on the canvas, for when it is opened.
fn show_colors(model: Model, name: String) -> Effect(Msg) {
  let shapes = colors_of(model, name)
  effect.from(fn(_) { render.set_recolors(shapes) })
}

// The drawings followed by each preset whose name isn't already taken, so a
// saved drawing is never replaced.
fn add_presets(drawings: List(#(String, String))) -> List(#(String, String)) {
  let missing =
    list.filter(presets.all, fn(preset) {
      list.key_find(drawings, preset.0) == Error(Nil)
    })
  list.append(drawings, missing)
}

// Parse and evaluate a draw function at the given shape-slider value, returning
// the rendered paths on success, or a human-readable message on failure.
fn run_source(shape_slider: Int, source: String) -> Result(List(Path), String) {
  case parser.parse_program(source, builtins.global_frame()) {
    Error(msg) -> Error(msg)
    Ok(program) ->
      drawing.try_draw(shape_slider, program)
      // Convert Error(EvalError) to Error(String) with a useful error message.
      |> result.map_error(errors.error_message)
  }
}

// Convert paths from draw into RenderPaths, scale the whole drawing by the size
// slider, and hand them to the canvas.
fn show_paths(paths: List(Path), shape_slider: Int) -> Nil {
  let scale = float.max(min_scale, int.to_float(shape_slider) /. normal_size)
  paths
  |> list.map(render.render_path(_, path_color))
  |> list.map(scale_path(_, scale))
  |> render.set_drawing
}

// Scale every point of a path toward or away from the canvas centre, (0, 0).
// Line thickness stays the same so lines don't turn blobby when enlarged.
fn scale_path(path: render.RenderPath, scale: Float) -> render.RenderPath {
  render.RenderPath(
    ..path,
    points: list.map(path.points, fn(p) { Point(p.x *. scale, p.y *. scale) }),
  )
}

// Replace the editor's text with source and animate it from the start.
// (Mounting alone doesn't run the code, so dispatch SetCode for it too.)
fn open_in_editor(source: String) -> Effect(Msg) {
  effect.batch([
    editor.mount(source, SetCode),
    effect.from(fn(dispatch) { dispatch(SetCode(source)) }),
  ])
}

// Read a number typed into a range input. The browser reports whole numbers
// without a decimal point ("2", "-1"), which float.parse rejects.
fn parse_number(text: String) -> Result(Float, Nil) {
  case float.parse(text) {
    Ok(x) -> Ok(x)
    Error(Nil) -> int.parse(text) |> result.map(int.to_float)
  }
}

// ── Update ─────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ToggleCode -> #(Model(..model, code_open: !model.code_open), effect.none())

    // When the drawing is fully drawn, start it over from an empty canvas,
    // unless coloring mode is on: then it stays drawn while the colour fills in.
    AnimationFinished ->
      case model.coloring {
        True -> #(model, effect.none())
        False -> #(model, effect.from(fn(_) { render.reset_clock() }))
      }

    // Switching coloring mode on or off restarts the drawing, so the outlines
    // trace again before (or without) the fill.
    ToggleColoring -> {
      let coloring = !model.coloring
      let color = case coloring {
        True -> model.fill_color
        False -> ""
      }
      #(
        Model(..model, coloring: coloring),
        effect.from(fn(_) {
          render.set_fill(color)
          render.reset_clock()
        }),
      )
    }

    // A new colour applies right away, without restarting the drawing.
    SetFillColor(color) -> apply_fill_color(model, color)

    // Same as SetFillColor, but then ignore palette swatch clicks briefly:
    // when the native picker closes, a leftover click often lands on a swatch
    // that was under the picker and would overwrite the new colour.
    SetFillColorFromPicker(color) -> {
      let token = model.picker_token + 1
      let #(model, fill) =
        apply_fill_color(
          Model(..model, ignore_swatch: True, picker_token: token),
          color,
        )
      #(
        model,
        effect.batch([
          fill,
          effect.from(fn(dispatch) {
            after(swatch_guard_ms, fn() { dispatch(AllowSwatches(token)) })
          }),
        ]),
      )
    }

    AllowSwatches(token) ->
      case token == model.picker_token {
        True -> #(Model(..model, ignore_swatch: False), effect.none())
        False -> #(model, effect.none())
      }

    // Hide or show fills without restarting the drawing or losing recolors.
    ToggleOutlineOnly -> {
      let on = !model.outline_only
      #(
        Model(..model, outline_only: on),
        effect.from(fn(_) { render.set_outline_only(on) }),
      )
    }

    // A shape was clicked once the fill finished: fill it with the picker's
    // colour from now on, and remember that.
    RecolorShape(index) ->
      case model.coloring {
        True -> {
          let #(model, recolor) =
            change_current_colors(
              model,
              list.key_set(current_colors(model), index, model.fill_color),
            )
          let #(model, remember) = use_color(model, model.fill_color)
          #(model, effect.batch([recolor, remember]))
        }
        False -> #(model, effect.none())
      }

    // A palette swatch was clicked: make its colour the picker's, just as if it
    // had been chosen in the colour picker. Ignored just after the native
    // picker closes, so a leftover click on a swatch under the picker cannot
    // overwrite the colour that was just picked.
    PickSwatch(color) ->
      case model.ignore_swatch {
        True -> #(model, effect.none())
        False -> apply_fill_color(model, color)
      }

    RecolorReady(ready) -> #(
      Model(..model, recolor_ready: ready),
      effect.none(),
    )

    // Forget the open drawing's recolors, back to the code's and the picker's
    // colours.
    // Resetting is one undoable step, so undo brings every recolor back.
    ResetColors -> change_current_colors(model, [])

    // Step back to the open drawing's recolors before its last click or reset,
    // exactly as they were, and save them.
    UndoColors ->
      case model.coloring, current_undo(model) {
        True, [previous, ..older] ->
          set_current_undo(model, older) |> set_current_colors(previous)
        _, _ -> #(model, effect.none())
      }

    // A new fill speed applies right away, even partway through a fill.
    SetFillSpeed(rate) -> #(
      Model(..model, fill_speed: rate),
      effect.from(fn(_) { render.set_fill_speed(rate) }),
    )

    // After each keystroke in the editor, evaluate user code and report errors.
    // Every edit, and every drawing opened from the menu, comes through here.
    SetCode(text) -> {
      // Editing the code can add, remove, or reorder shapes, which would move
      // recolors onto the wrong ones, so any change forgets the drawing's
      // recolors. (Opening a drawing also comes through here, unchanged.)
      let #(model, clear_colors) = case
        list.key_find(model.drawings, model.selected)
      {
        Ok(old) if old != text && model.selected != "" -> {
          // The history would restore recolors onto the wrong shapes too.
          let model = set_current_undo(model, [])
          case current_colors(model) {
            [] -> #(model, effect.none())
            _ -> set_current_colors(model, [])
          }
        }
        _ -> #(model, effect.none())
      }
      // Remember the edit under the selected drawing, so switching away and
      // back keeps it.
      let model =
        Model(
          ..model,
          drawings: list.map(model.drawings, fn(d) {
            case d.0 == model.selected {
              True -> #(d.0, text)
              False -> d
            }
          }),
        )
      // Save the library (and which drawing is open) to localStorage, whether
      // or not the code works, so reloading loses nothing.
      let drawings = model.drawings
      let selected = model.selected
      let save = effect.from(fn(_) { data.save_library(drawings, selected) })
      case run_source(model.shape_slider, text) {
        // Parsed and evaluated: animate the paths from the start.
        Ok(paths) -> #(
          Model(..model, error: None, source: text),
          effect.batch([
            save,
            clear_colors,
            effect.from(fn(_) {
              show_paths(paths, model.shape_slider)
              render.reset_clock()
            }),
          ]),
        )
        // Broken (parse or evaluation): show the code's error instead of a
        // drawing.
        Error(msg) -> #(
          Model(..model, error: Some(msg), source: text),
          effect.batch([save, clear_colors]),
        )
      }
    }

    // Redraw at the new size without restarting the clock, so a drawing in
    // progress keeps going and a finished one shows the new size. The value is
    // still passed to draw as shape_slider, and also scales the whole drawing.
    SetShapeSlider(value) -> {
      let model = Model(..model, shape_slider: value)
      case run_source(value, model.source) {
        Ok(paths) -> #(
          Model(..model, error: None),
          effect.from(fn(_) { show_paths(paths, value) }),
        )
        Error(msg) -> #(Model(..model, error: Some(msg)), effect.none())
      }
    }

    SetSpeed(rate) -> #(
      Model(..model, speed: rate),
      effect.from(fn(_) { render.set_speed(rate) }),
    )

    // "New drawing…" was picked: ask for its name. (The menu's on_change
    // usually prompts in the event handler; this is the fallback.)
    SelectDrawing(name) if name == new_drawing_option -> #(
      model,
      effect.from(fn(dispatch) {
        dispatch(ask_new_drawing_name(model.selected))
      }),
    )

    // A named drawing was picked: load its source into the editor.
    SelectDrawing(name) ->
      case list.key_find(model.drawings, name) {
        Ok(source) -> #(
          Model(..model, selected: name),
          effect.batch([show_colors(model, name), open_in_editor(source)]),
        )
        Error(Nil) -> #(model, effect.none())
      }

    // Cancelled, or a name that's only spaces: put the menu back on the
    // drawing that's still showing.
    NewDrawingNamed(raw) -> {
      let name = string.trim(raw)
      case name {
        "" ->
          case data.prompt_was_blocked() {
            // The dialog never appeared: offer an on-page name field instead
            // of silently going back to the current drawing.
            True -> #(
              Model(..model, naming: True, naming_text: ""),
              effect.from(fn(_) {
                set_select_value("drawing-select", model.selected)
                focus_selector("[data-test-id=new-drawing-name]")
              }),
            )
            False -> #(
              Model(..model, naming: False, naming_text: ""),
              effect.from(fn(_) {
                set_select_value("drawing-select", model.selected)
              }),
            )
          }
        _ ->
          case list.key_find(model.drawings, name) {
            // That name is taken, so just switch to the existing drawing.
            Ok(source) -> #(
              Model(..model, selected: name, naming: False, naming_text: ""),
              effect.batch([show_colors(model, name), open_in_editor(source)]),
            )
            // Add it to the end of the menu, with a blank starter that parses
            // and draws nothing, so the editor is reset and the canvas is empty.
            Error(Nil) -> #(
              Model(
                ..model,
                drawings: list.append(model.drawings, [
                  #(name, new_drawing_code),
                ]),
                selected: name,
                naming: False,
                naming_text: "",
              ),
              effect.batch([
                show_colors(model, name),
                open_in_editor(new_drawing_code),
              ]),
            )
          }
      }
    }

    SetNamingText(text) -> #(Model(..model, naming_text: text), effect.none())

    ConfirmNewDrawing ->
      case string.trim(model.naming_text) {
        "" -> update(model, CancelNaming)
        _ -> update(model, NewDrawingNamed(model.naming_text))
      }

    CancelNaming -> #(
      Model(..model, naming: False, naming_text: ""),
      effect.from(fn(_) { set_select_value("drawing-select", model.selected) }),
    )
  }
}

// ── View ──────────────────────────────────────────────────────────────────
//
// Two side-by-side panes: the code editor on the left and its rendered output on
// the right. The code column can be hidden to expand the right pane.

pub fn view(model: Model) -> Element(Msg) {
  let app_class = case model.code_open {
    True -> "app"
    False -> "app code-hidden"
  }
  // The code column still exists even when hidden (CSS collapses it) so the
  // mounted CodeMirror editor keeps its state across show/hide.
  html.div([attr.class(app_class)], [
    html.div([attr.class("code-col")], [
      editor.view_panel(ToggleCode),
    ]),
    view_anim(model),
  ])
}

fn view_anim(model: Model) -> Element(Msg) {
  html.div([attr.class("canvas-area")], [
    view_reveal_code(model),
    case model.error {
      // The paths animate on this canvas (see render.set_drawing).
      None -> html.canvas([attr.id("animation-canvas"), attr.class("canvas")])
      // The code is broken, so explain why where the drawing would be.
      Some(msg) -> html.pre([attr.class("output")], [html.text(msg)])
    },
    view_controls(model),
  ])
}

// The sliders along the bottom of the animation pane.
fn view_controls(model: Model) -> Element(Msg) {
  html.div([attr.class("controls")], [
    view_drawing_select(model),
    view_slider(
      label: "size",
      readout: int.to_string(model.shape_slider),
      attributes: [
        attr.attribute("data-test-id", "shape-slider"),
        attr.min("0"),
        attr.max("100"),
        attr.step("1"),
        attr.value(int.to_string(model.shape_slider)),
        event.on_input(fn(text) {
          SetShapeSlider(result.unwrap(int.parse(text), model.shape_slider))
        }),
      ],
    ),
    view_slider(
      label: "speed",
      readout: float.to_string(model.speed) <> "×",
      attributes: [
        attr.attribute("data-test-id", "speed-slider"),
        attr.min(float.to_string(min_speed)),
        attr.max(float.to_string(max_speed)),
        attr.step("0.1"),
        attr.value(float.to_string(model.speed)),
        event.on_input(fn(text) {
          SetSpeed(result.unwrap(parse_number(text), model.speed))
        }),
      ],
    ),
    view_coloring(model),
    view_slider(
      label: "fill speed",
      readout: float.to_string(model.fill_speed) <> "×",
      attributes: [
        attr.attribute("data-test-id", "fill-speed-slider"),
        attr.class("fill-speed"),
        attr.attribute("title", "How fast colours fill in"),
        attr.min(float.to_string(min_fill_speed)),
        attr.max(float.to_string(max_fill_speed)),
        attr.step("0.25"),
        attr.value(float.to_string(model.fill_speed)),
        event.on_input(fn(text) {
          SetFillSpeed(result.unwrap(parse_number(text), model.fill_speed))
        }),
      ],
    ),
    view_palette(model),
  ])
}

// The coloring mode button and the colour it fills with.
fn view_coloring(model: Model) -> Element(Msg) {
  let button_class = case model.coloring {
    True -> "coloring-btn on"
    False -> "coloring-btn"
  }
  html.div([attr.class("slider")], [
    html.button(
      [
        attr.class(button_class),
        attr.attribute("aria-pressed", case model.coloring {
          True -> "true"
          False -> "false"
        }),
        event.on_click(ToggleColoring),
      ],
      [html.text("Coloring mode")],
    ),
    html.input([
      attr.type_("color"),
      attr.class("fill-color"),
      attr.attribute("title", "Fill colour"),
      attr.value(model.fill_color),
      event.on_input(SetFillColorFromPicker),
      event.on_change(SetFillColorFromPicker),
    ]),
    html.span([attr.class("slider-value")], [
      html.text(rgb_text(model.fill_color)),
    ]),
    view_outline_only(model),
    view_recolor_controls(model),
  ])
}

// Always available: hides fills so only outlines show, in the colours they
// would otherwise have. Recoloring a shape still works in this mode; the
// outline takes the new colour at once (the fill has already finished).
fn view_outline_only(model: Model) -> Element(Msg) {
  let on = model.outline_only
  html.button(
    [
      attr.class(case on {
        True -> "coloring-btn on"
        False -> "coloring-btn"
      }),
      attr.attribute("data-test-id", "outline-toggle"),
      attr.attribute("aria-pressed", case on {
        True -> "true"
        False -> "false"
      }),
      attr.attribute("title", "Show only outlines, hiding fills"),
      event.on_click(ToggleOutlineOnly),
    ],
    [html.text("outline only")],
  )
}

// In coloring mode: the buttons that forget the open drawing's recolors and
// undo the last recolor or reset, and a hint once shapes can be clicked to recolor them.
fn view_recolor_controls(model: Model) -> Element(Msg) {
  case model.coloring {
    False -> element.none()
    True ->
      element.fragment([
        html.button(
          [
            attr.class("coloring-btn reset-colors-btn"),
            attr.attribute("data-test-id", "reset-colors"),
            attr.attribute("title", "Go back to the original fill colours"),
            attr.disabled(current_colors(model) == []),
            event.on_click(ResetColors),
          ],
          [html.text("reset colors")],
        ),
        html.button(
          [
            attr.class("coloring-btn undo-colors-btn"),
            attr.attribute("data-test-id", "undo-colors"),
            attr.attribute(
              "title",
              "Go back to the colours before the last change",
            ),
            attr.disabled(current_undo(model) == []),
            event.on_click(UndoColors),
          ],
          [html.text("undo")],
        ),
        case model.recolor_ready {
          True ->
            html.span([attr.class("recolor-hint")], [
              html.text("click a shape to recolor"),
            ])
          False -> element.none()
        },
      ])
  }
}

// In coloring mode, a row of the recently used colours along the bottom of the
// controls: clicking one makes it the picker's colour. Unused slots show as
// faint placeholders so the row keeps its size.
fn view_palette(model: Model) -> Element(Msg) {
  case model.coloring {
    False -> element.none()
    True -> {
      let swatches =
        list.map(model.palette, fn(color) {
          let class = case color == model.fill_color {
            True -> "palette-swatch current"
            False -> "palette-swatch"
          }
          html.button(
            [
              attr.class(class),
              attr.attribute("data-test-id", "palette-swatch"),
              attr.attribute("data-color", color),
              attr.attribute("title", rgb_text(color)),
              attr.attribute("aria-label", rgb_text(color)),
              attr.style("background", color),
              event.on_click(PickSwatch(color)),
            ],
            [],
          )
        })
      let empty =
        list.repeat(
          html.span([attr.class("palette-swatch empty")], []),
          palette_size - list.length(model.palette),
        )
      html.div(
        [
          attr.class(case model.ignore_swatch {
            True -> "slider palette inert"
            False -> "slider palette"
          }),
        ],
        [
          html.span([attr.class("slider-label")], [html.text("palette")]),
          ..list.append(swatches, empty)
        ],
      )
    }
  }
}

// "#rrggbb" as "rgb(r, g, b)", the way the colour is described to the user.
fn rgb_text(hex: String) -> String {
  let channel = fn(start) {
    string.slice(hex, start, 2)
    |> int.base_parse(16)
    |> result.unwrap(0)
    |> int.to_string
  }
  "rgb(" <> channel(1) <> ", " <> channel(3) <> ", " <> channel(5) <> ")"
}

// The drop-down menu of drawings, ending with an option to create a new one.
fn view_drawing_select(model: Model) -> Element(Msg) {
  let options =
    list.map(model.drawings, fn(d) {
      html.option([attr.value(d.0), attr.selected(d.0 == model.selected)], d.0)
    })
  html.label([attr.class("slider")], [
    html.span([attr.class("slider-label")], [html.text("drawing")]),
    view_naming_form(model),
    html.select(
      [
        attr.attribute("data-test-id", "drawing-select"),
        attr.class("drawing-select"),
        attr.value(model.selected),
        event.on_change(fn(name) {
          case name == new_drawing_option {
            True -> ask_new_drawing_name(model.selected)
            False -> SelectDrawing(name)
          }
        }),
      ],
      list.append(options, [
        html.option([attr.value(new_drawing_option)], "+ New drawing…"),
      ]),
    ),
  ])
}

fn view_naming_form(model: Model) -> Element(Msg) {
  case model.naming {
    False -> element.none()
    True ->
      html.span([attr.class("new-drawing-form")], [
        html.span([attr.class("slider-label")], [
          html.text("Name for the new drawing:"),
        ]),
        html.input([
          attr.type_("text"),
          attr.attribute("data-test-id", "new-drawing-name"),
          attr.class("new-drawing-name"),
          attr.placeholder("drawing name"),
          attr.value(model.naming_text),
          event.on_input(SetNamingText),
          event.on_keydown(fn(key) {
            case key {
              "Enter" -> ConfirmNewDrawing
              "Escape" -> CancelNaming
              _ -> SetNamingText(model.naming_text)
            }
          }),
        ]),
        html.button(
          [
            attr.class("coloring-btn"),
            attr.attribute("data-test-id", "new-drawing-create"),
            event.on_click(ConfirmNewDrawing),
          ],
          [html.text("Create")],
        ),
        html.button(
          [
            attr.class("coloring-btn"),
            attr.attribute("data-test-id", "new-drawing-cancel"),
            event.on_click(CancelNaming),
          ],
          [html.text("Cancel")],
        ),
      ])
  }
}

// One labelled range input with its current value shown beside it.
fn view_slider(
  label label: String,
  readout readout: String,
  attributes attributes: List(attr.Attribute(Msg)),
) -> Element(Msg) {
  html.label([attr.class("slider")], [
    html.span([attr.class("slider-label")], [html.text(label)]),
    html.input([attr.type_("range"), ..attributes]),
    html.span([attr.class("slider-value")], [html.text(readout)]),
  ])
}

// The button that brings the code column back, overlaid on the top-left of the
// right pane. Nothing is rendered while the column is already showing (its own
// header holds the button that hides it).
fn view_reveal_code(model: Model) -> Element(Msg) {
  case model.code_open {
    True -> element.none()
    False ->
      html.button(
        [
          attr.class("icon-btn reveal-code"),
          attr.attribute("title", "Show code"),
          event.on_click(ToggleCode),
        ],
        [html.text("⟩")],
      )
  }
}

// ── Main ───────────────────────────────────────────────────────────────────────

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
