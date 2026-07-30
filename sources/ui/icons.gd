class_name Icons
extends Object
## The two icons the interface needs, drawn at runtime.
##
## Generating them keeps the repository free of binary assets for what amounts
## to a triangle and a square, and lets them follow the text colour.

## Drawn this many times larger and scaled back down, which is what gives the
## triangle a smooth edge.
const _SUPERSAMPLE: int = 4


static func play(size: int = 22, color: Color = Color.WHITE) -> ImageTexture:
	return _render(size, color, _is_inside_play_triangle)


static func stop(size: int = 22, color: Color = Color.WHITE) -> ImageTexture:
	return _render(size, color, _is_inside_stop_square)


## `test` takes normalized coordinates in 0..1 and says whether to fill.
static func _render(size: int, color: Color, test: Callable) -> ImageTexture:
	var resolution: int = size * _SUPERSAMPLE
	var image: Image = Image.create_empty(resolution, resolution, false, Image.FORMAT_RGBA8)
	image.fill(Color(color.r, color.g, color.b, 0.0))

	for y: int in resolution:
		var normalized_y: float = (float(y) + 0.5) / float(resolution)
		for x: int in resolution:
			var normalized_x: float = (float(x) + 0.5) / float(resolution)
			if test.call(normalized_x, normalized_y):
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
