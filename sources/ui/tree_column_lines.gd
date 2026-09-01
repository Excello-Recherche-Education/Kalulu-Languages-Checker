class_name TreeColumnLines
extends Control
## Vertical rules between the columns of a Tree, drawn on top of it.
##
## Tree draws a guide between rows but nothing between columns, and with five
## columns — two of them free text — a tester reading across a row loses which
## cell they are in. Godot's Tree theme has no property for this, so the rules
## are drawn here, from the geometry the Tree itself reports, which means they
## follow a column being resized and the list being scrolled.

## The accent blue of the headings, faint: it has to separate five columns of
## small text without competing with the text itself.
const LINE_COLOR: Color = Color("8ecae6", 0.45)
const LINE_WIDTH: float = 1.0

var _tree: Tree = null
## The last geometry drawn: [title height, boundary x…]. Compared every frame,
## because a column resize and a scroll are neither of them a signal.
var _geometry: PackedFloat32Array = PackedFloat32Array()


func _init(tree: Tree) -> void:
	_tree = tree
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var current: PackedFloat32Array = _read_geometry()
	if current != _geometry:
		_geometry = current
		queue_redraw()


func _draw() -> void:
	if _geometry.size() < 2:
		return
	var top: float = _geometry[0]
	for index: int in range(1, _geometry.size()):
		draw_line(
				Vector2(_geometry[index], top),
				Vector2(_geometry[index], size.y),
				LINE_COLOR,
				LINE_WIDTH)


## Where to draw: the height of the title row, then the right edge of every
## column but the last. Empty when the Tree has no rows to measure.
func _read_geometry() -> PackedFloat32Array:
	var result: PackedFloat32Array = PackedFloat32Array()
	if _tree == null:
		return result
	var root: TreeItem = _tree.get_root()
	if root == null:
		return result
	var first: TreeItem = root.get_first_child()
	if first == null:
		return result

	# A cell rect is given in the Tree's own coordinates, so the first row sits
	# at the height of the titles minus however far the list is scrolled. Adding
	# the scroll back gives the title height, which is where the rules start.
	var scroll: Vector2 = _tree.get_scroll()
	result.append(_tree.get_item_area_rect(first, 0).position.y + scroll.y)
	for column: int in _tree.columns - 1:
		result.append(_tree.get_item_area_rect(first, column).end.x)
	return result
