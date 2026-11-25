//// The drawing Path types produced by the evaluator and rendered by the
//// animator.
////
//// The canvas maps a 1000-wide box centred on the origin onto its full size, and
//// x, y, and thickness are all in those units.

/// A point in world coordinates.
pub type Point {
  Point(x: Float, y: Float)
}

pub type Shape {
  Line(start: Point, end: Point)
  // A closed outline through the points in order, ending back at the first.
  Polygon(points: List(Point))
  // A circle drawn clockwise from its rightmost point.
  Circle(center: Point, radius: Float)
}

pub type Path {
  // start and end are the times (in tenths of a second) between which the path is
  // drawn: the reveal runs linearly from nothing at start to the complete shape at
  // end. A path with end <= start appears complete the moment it starts.
  // color is the outline's CSS colour and fill the colour its closed shape
  // fills with once every outline is drawn; "" means the default outline
  // colour, and no fill of its own (coloring mode's colour, if it's on).
  Path(
    shape: Shape,
    start: Float,
    end: Float,
    thickness: Float,
    color: String,
    fill: String,
  )
}
