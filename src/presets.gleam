//// Ready-made coloured drawings for the extension: a square, a diamond, and a
//// bear, built from Polygon, Circle, and the colour built-ins (rgb, colored,
//// outlined). Every library gets them, alongside examples.all: a browser with
//// nothing saved starts with both, and a saved library that lacks one gains it
//// when the app opens, without touching any saved drawing.

pub const all = [
  #(
    "square",
    "fn draw(shape_slider: Int) -> List(Path) {
  let s = 200
  let corners = [Point(0 - s, 0 - s), Point(s, 0 - s), Point(s, s), Point(0 - s, s)]
  [colored(Path(Polygon(corners), 0, 20, 6), rgb(20, 50, 120), rgb(70, 140, 240))]
}
",
  ),
  #(
    "diamond",
    "fn draw(shape_slider: Int) -> List(Path) {
  [
    colored(Path(diamond(260, 180), 0, 20, 6), rgb(90, 20, 90), rgb(200, 60, 160)),
    colored(Path(diamond(130, 90), 20, 30, 4), rgb(90, 20, 90), rgb(250, 170, 220)),
  ]
}

fn diamond(tall: Int, wide: Int) -> Shape {
  Polygon([Point(0, 0 - tall), Point(wide, 0), Point(0, tall), Point(0 - wide, 0)])
}
",
  ),
  #(
    "bear",
    "fn draw(shape_slider: Int) -> List(Path) {
  let fur = rgb(150, 95, 50)
  let dark = rgb(60, 35, 20)
  list.flatten([
    ear(-170, fur),
    ear(170, fur),
    [colored(Path(Circle(Point(0, 20), 220), 10, 25, 6), dark, fur)],
    [colored(Path(Circle(Point(0, 100), 90), 25, 32, 4), dark, rgb(235, 200, 150))],
    eye(-80),
    eye(80),
    [
      colored(Path(Polygon([Point(-40, 55), Point(40, 55), Point(0, 95)]), 38, 42, 4), dark, dark),
      outlined(Path(Line(Point(0, 95), Point(0, 130)), 42, 44, 4), dark),
      outlined(Path(Line(Point(0, 130), Point(-30, 150)), 44, 46, 4), dark),
      outlined(Path(Line(Point(0, 130), Point(30, 150)), 44, 46, 4), dark),
    ],
  ])
}

// An ear: brown all round (so no line shows where the head covers it), with a
// pink inside.
fn ear(x: Int, fur: Rgb) -> List(Path) {
  [
    colored(Path(Circle(Point(x, -175), 80), 0, 10, 4), fur, fur),
    colored(Path(Circle(Point(x + x / 34, -180), 38), 0, 10, 3), rgb(200, 115, 105), rgb(240, 160, 150)),
  ]
}

// An eye with a white glint.
fn eye(x: Int) -> List(Path) {
  [
    colored(Path(Circle(Point(x, -40), 22), 32, 36, 3), rgb(30, 20, 15), rgb(30, 20, 15)),
    colored(Path(Circle(Point(x + 8, -48), 7), 36, 38, 2), rgb(255, 255, 255), rgb(255, 255, 255)),
  ]
}
",
  ),
]
