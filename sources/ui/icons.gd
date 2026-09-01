class_name Icons
extends Object
## The icons the interface needs, drawn at runtime.
##
## Generating them keeps the repository free of binary assets for what amounts
## to a triangle, a square and a tick box, and lets them follow the text colour.

## Drawn this many times larger and scaled back down, which is what gives the
## triangle a smooth edge.
const _SUPERSAMPLE: int = 4

## Half the width of the tick box, and the thickness of its border, normalized.
const _BOX_HALF_SIZE: float = 0.42
const _BOX_BORDER: float = 0.10
## The tick: a short stroke down to the corner, then a long one back up.
const _TICK_START: Vector2 = Vector2(0.24, 0.52)
const _TICK_CORNER: Vector2 = Vector2(0.42, 0.70)
const _TICK_END: Vector2 = Vector2(0.76, 0.28)
const _TICK_THICKNESS: float = 0.09


static func play(size: int = 22, color: Color = Color.WHITE) -> ImageTexture:
	return _render(size, color, _is_inside_play_triangle)


static func stop(size: int = 22, color: Color = Color.WHITE) -> ImageTexture:
	return _render(size, color, _is_inside_stop_square)


## The tick box of the "Problem?" column, replacing the Tree's own. Godot draws
## a small, low-contrast box, and a tester scanning thousands of rows has to see
## at a glance which ones they have already flagged — so this one is larger, has
## a visible border, and fills solid when ticked.
static func check_box(
		size: int,
		ticked: bool,
		box_color: Color,
		mark_color: Color = Color.BLACK) -> ImageTexture:
	# Transparent pixels keep the box colour so scaling down cannot fringe the
	# edges with black, which is what _render does for the same reason.
	var clear: Color = Color(box_color.r, box_color.g, box_color.b, 0.0)
	return _render_colors(size, clear, func (x: float, y: float) -> Color:
		if not _is_inside_square(x, y, _BOX_HALF_SIZE):
			return clear
		if not ticked:
			var inside: bool = _is_inside_square(
					x, y, _BOX_HALF_SIZE - _BOX_BORDER)
			return clear if inside else box_color
		return mark_color if _is_on_tick(x, y) else box_color
	)


## `test` takes normalized coordinates in 0..1 and says whether to fill.
static func _render(size: int, color: Color, test: Callable) -> ImageTexture:
	var clear: Color = Color(color.r, color.g, color.b, 0.0)
	return _render_colors(size, clear, func (x: float, y: float) -> Color:
		return color if test.call(x, y) else clear
	)


## `test` takes normalized coordinates in 0..1 and returns the colour to write.
## `clear` is what the image starts as, and must share the RGB of what is drawn
## on top of it: scaling down blends into the transparent pixels, so a black
## `clear` would darken every edge.
static func _render_colors(size: int, clear: Color, test: Callable) -> ImageTexture:
	var resolution: int = size * _SUPERSAMPLE
	var image: Image = Image.create_empty(resolution, resolution, false, Image.FORMAT_RGBA8)
	image.fill(clear)

	for y: int in resolution:
		var normalized_y: float = (float(y) + 0.5) / float(resolution)
		for x: int in resolution:
			var normalized_x: float = (float(x) + 0.5) / float(resolution)
			var color: Color = test.call(normalized_x, normalized_y)
			if color.a > 0.0:
				image.set_pixel(x, y, color)

	image.resize(size, size, Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(image)


## Right-pointing triangle. The filled span narrows to nothing at the tip.
static func _is_inside_play_triangle(x: float, y: float) -> bool:
	const LEFT: float = 0.22
	const RIGHT: float = 0.86
	const HALF_HEIGHT: float = 0.36

	var distance_from_middle: float = absf(y - 0.5)
	if distance_from_middle > HALF_HEIGHT:
		return false
	var span: float = (RIGHT - LEFT) * (1.0 - distance_from_middle / HALF_HEIGHT)
	return x >= LEFT and x <= LEFT + span


static func _is_inside_stop_square(x: float, y: float) -> bool:
	return x >= 0.24 and x <= 0.76 and y >= 0.24 and y <= 0.76


static func _is_inside_square(x: float, y: float, half_size: float) -> bool:
	return maxf(absf(x - 0.5), absf(y - 0.5)) <= half_size


static func _is_on_tick(x: float, y: float) -> bool:
	var point: Vector2 = Vector2(x, y)
	var half: float = _TICK_THICKNESS * 0.5
	return point.distance_to(Geometry2D.get_closest_point_to_segment(
					point, _TICK_START, _TICK_CORNER)) <= half \
			or point.distance_to(Geometry2D.get_closest_point_to_segment(
					point, _TICK_CORNER, _TICK_END)) <= half
