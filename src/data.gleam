//// The library of saved drawings. A drawing is a name and the source of its draw
//// function.

import gleam/int
import gleam/list
import gleam/string

// ── localStorage (data_ffi.mjs) ───────────────────────────────────────────────

/// The string stored in localStorage under key, or an Error if there isn't one.
@external(javascript, "./data_ffi.mjs", "storageGet")
pub fn storage_get(key: String) -> Result(String, Nil)

/// Store value in localStorage under key, replacing anything already there. If that
/// isn't possible, this logs the reason to the browser console.
@external(javascript, "./data_ffi.mjs", "storageSet")
pub fn storage_set(key: String, value: String) -> Nil

// ── The new-drawing prompt (data_ffi.mjs) ─────────────────────────────────────

/// Prompt the user to name a new drawing; "" (empty string) means they
/// cancelled or left it blank.
@external(javascript, "./data_ffi.mjs", "promptDrawingName")
pub fn prompt_drawing_name() -> String

/// True when the last prompt_drawing_name call was blocked by the browser
/// (it returned immediately with no dialog) rather than cancelled by the user.
@external(javascript, "./data_ffi.mjs", "promptWasBlocked")
pub fn prompt_was_blocked() -> Bool

// ── The saved library ─────────────────────────────────────────────────────────
//
// The whole library lives under one localStorage key as plain text, with every
// drawing's code stored exactly as typed (no escaping):
//
//   animator-library-v1
//   <name of the open drawing>
//   \u{1E}<name>
//   <source…>
//   \u{1E}<name>
//   <source…>
//
// The ASCII record separator (U+001E) starts each drawing. Nobody types it, so
// it can't clash with code, and names come from a one-line prompt, so the
// first line of each record is always the whole name.

/// The localStorage key that holds the library.
const library_key = "animator-library"

/// The first line of a saved library, so other data under the key is ignored.
const header = "animator-library-v1"

const separator = "\u{1E}"

/// Save every drawing, as #(name, source), and the name of the open one.
pub fn save_library(
  drawings: List(#(String, String)),
  selected: String,
) -> Nil {
  let records =
    list.map(drawings, fn(drawing) {
      separator <> drawing.0 <> "\n" <> drawing.1
    })
  storage_set(
    library_key,
    string.concat([header, "\n", selected, "\n", ..records]),
  )
}

/// The saved drawings and the name of the drawing that was open, or an Error if
/// nothing (or nothing readable) is saved.
pub fn load_library() -> Result(#(List(#(String, String)), String), Nil) {
  case storage_get(library_key) {
    Error(Nil) -> Error(Nil)
    Ok(text) ->
      case string.split(text, separator) {
        [top, ..records] ->
          case string.split_once(top, "\n") {
            Ok(#(first_line, rest)) if first_line == header -> {
              let selected = string.replace(rest, "\n", "")
              let drawings = list.filter_map(records, parse_record)
              case drawings {
                [] -> Error(Nil)
                _ -> Ok(#(drawings, selected))
              }
            }
            _ -> Error(Nil)
          }
        [] -> Error(Nil)
      }
  }
}

// One "<name>\n<source>" record, or an Error if it has no name line.
fn parse_record(record: String) -> Result(#(String, String), Nil) {
  case string.split_once(record, "\n") {
    Ok(#(name, source)) if name != "" -> Ok(#(name, source))
    _ -> Error(Nil)
  }
}

// ── Saved recolors ────────────────────────────────────────────────────────────
//
// The fill colours picked for single shapes by clicking them in coloring mode
// live under their own key, so the library above (and the code in it) is never
// touched:
//
//   animator-colors-v1
//   \u{1E}<drawing name>
//   <shape index> <colour>
//   <shape index> <colour>
//   \u{1E}<drawing name>
//   ...

/// The localStorage key that holds every drawing's recolors.
const colors_key = "animator-colors"

const colors_header = "animator-colors-v1"

/// The first line of saved recolors, with its line break, as load_colors
/// finds it before the first record.
const colors_top = "animator-colors-v1\n"

/// Save every drawing's recolors, as #(drawing name, [#(shape index, colour)]).
/// Drawings with no recolors are left out.
pub fn save_colors(colors: List(#(String, List(#(Int, String))))) -> Nil {
  let records =
    list.filter_map(colors, fn(drawing) {
      case drawing.1 {
        [] -> Error(Nil)
        shapes ->
          Ok(
            separator
            <> drawing.0
            <> "\n"
            <> string.join(
              list.map(shapes, fn(shape) {
                int.to_string(shape.0) <> " " <> shape.1
              }),
              "\n",
            )
            <> "\n",
          )
      }
    })
  storage_set(colors_key, string.concat([colors_header, "\n", ..records]))
}

/// The saved recolors of every drawing, or [] if none (or none readable) are
/// saved.
pub fn load_colors() -> List(#(String, List(#(Int, String)))) {
  case storage_get(colors_key) {
    Error(Nil) -> []
    Ok(text) ->
      case string.split(text, separator) {
        [top, ..records] if top == colors_top ->
          list.filter_map(records, parse_colors_record)
        _ -> []
      }
  }
}

// One "<name>\n<index> <colour>\n..." record.
fn parse_colors_record(
  record: String,
) -> Result(#(String, List(#(Int, String))), Nil) {
  case string.split(record, "\n") {
    [name, ..lines] if name != "" ->
      Ok(#(
        name,
        list.filter_map(lines, fn(line) {
          case string.split_once(line, " ") {
            Ok(#(index, color)) ->
              case int.parse(index) {
                Ok(i) if color != "" -> Ok(#(i, color))
                _ -> Error(Nil)
              }
            Error(Nil) -> Error(Nil)
          }
        }),
      ))
    _ -> Error(Nil)
  }
}

// ── Saved palette ─────────────────────────────────────────────────────────────
//
// The recently used colours, newest first, one "#rrggbb" per line after a
// header, under their own key:
//
//   animator-palette-v1
//   #ff0000
//   #00aa55

/// The localStorage key that holds the palette.
const palette_key = "animator-palette"

const palette_header = "animator-palette-v1"

/// Save the palette's colours, newest first.
pub fn save_palette(colors: List(String)) -> Nil {
  storage_set(palette_key, string.join([palette_header, ..colors], "\n"))
}

/// The saved palette's colours, newest first, or [] if none (or none readable)
/// are saved. Anything that isn't a "#rrggbb" colour is skipped.
pub fn load_palette() -> List(String) {
  case storage_get(palette_key) {
    Ok(text) ->
      case string.split(text, "\n") {
        [first, ..colors] if first == palette_header ->
          list.filter(colors, fn(c) {
            string.length(c) == 7 && string.starts_with(c, "#")
          })
        _ -> []
      }
    Error(Nil) -> []
  }
}
