class_name CheckList
extends VBoxContainer
## One tab of the checker: every entry of a category, with its sound, a box to
## tick when something is wrong and a place to say what.
##
## A pack holds up to 2500 words, so the rows live in a Tree rather than in
## instantiated scenes: a Tree only draws what is on screen, which keeps a full
## word list responsive in a browser.

signal play_requested(entry: Checkable)
signal report_changed

const COLUMN_LESSON: int = 0
const COLUMN_TEXT: int = 1
const COLUMN_SOUND: int = 2
const COLUMN_PROBLEM: int = 3
const COLUMN_COMMENT: int = 4
const COLUMN_COUNT: int = 5

const PLAY_BUTTON_ID: int = 0

const MISSING_SOUND_LABEL: String = "missing"
const NO_SOUND_LABEL: String = "—"

const PROBLEM_COLOR: Color = Color("ffd166")
const MISSING_COLOR: Color = Color("ef767a")
const MUTED_COLOR: Color = Color("8d99ae")

var category: String = ""

var _entries: Array[Checkable] = []
var _store: ReportStore = null
var _tree: Tree = null
var _play_icon: Texture2D = null
var _summary: Label = null
## Rows currently in the Tree, which is fewer than `_entries` when filtering.
var _shown_count: int = 0
## Entries the pack has no recording for. Fixed once the pack is open.
var _missing_sound_count: int = 0

# Active filters.
var _search: String = ""
var _lesson_filter: int = 0          # 0 = every lesson
var _only_problems: bool = false
var _only_missing_sounds: bool = false


func _init() -> void:
	add_theme_constant_override("separation", 6)


func _ready() -> void:
	_play_icon = Icons.play(18, Color("e8eef2"))

	_tree = Tree.new()
	_tree.columns = COLUMN_COUNT
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.allow_reselect = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_tree.set_column_title(COLUMN_LESSON, "Lesson")
	_tree.set_column_title(COLUMN_TEXT, "Text")
	_tree.set_column_title(COLUMN_SOUND, "Sound")
	_tree.set_column_title(COLUMN_PROBLEM, "Problem?")
	_tree.set_column_title(COLUMN_COMMENT, "What is wrong")

	_tree.set_column_expand(COLUMN_LESSON, false)
	_tree.set_column_custom_minimum_width(COLUMN_LESSON, 80)
	_tree.set_column_expand(COLUMN_SOUND, false)
	_tree.set_column_custom_minimum_width(COLUMN_SOUND, 90)
	_tree.set_column_expand(COLUMN_PROBLEM, false)
	_tree.set_column_custom_minimum_width(COLUMN_PROBLEM, 100)
	_tree.set_column_expand_ratio(COLUMN_TEXT, 2)
	_tree.set_column_expand_ratio(COLUMN_COMMENT, 3)
	_tree.set_column_clip_content(COLUMN_TEXT, true)
	_tree.set_column_clip_content(COLUMN_COMMENT, true)

	_tree.button_clicked.connect(_on_button_clicked)
	_tree.item_edited.connect(_on_item_edited)
	_tree.item_activated.connect(_on_item_activated)
	add_child(_tree)

	_summary = Label.new()
	_summary.add_theme_color_override("font_color", MUTED_COLOR)
	add_child(_summary)

	# setup() is normally called before this node is added to the scene, so the
	# rows it could not build yet are built now.
	if _store != null:
		rebuild()


## Hands the list its data. Safe to call before the node enters the tree.
func setup(p_category: String, entries: Array[Checkable], store: ReportStore) -> void:
	category = p_category
	_entries = entries
	_store = store
	name = p_category
	_missing_sound_count = 0
	for entry: Checkable in _entries:
		if entry.has_missing_sound():
			_missing_sound_count += 1
	if is_node_ready():
		rebuild()


func set_filters(
		search: String,
		lesson: int,
		only_problems: bool,
		only_missing_sounds: bool) -> void:
	_search = search.strip_edges().to_lower()
	_lesson_filter = lesson
	_only_problems = only_problems
	_only_missing_sounds = only_missing_sounds
	rebuild()


## Every lesson number present in this category, ascending.
func lessons() -> Array[int]:
	var seen: Dictionary[int, bool] = {}
	for entry: Checkable in _entries:
		if entry.lesson > 0:
			seen[entry.lesson] = true
	var result: Array[int] = []
	result.assign(seen.keys())
	result.sort()
	return result


func rebuild() -> void:
	if _tree == null:
		return

	_tree.clear()
	_shown_count = 0
	var root: TreeItem = _tree.create_item()

	for entry: Checkable in _entries:
		if not _passes_filters(entry):
			continue
		_add_row(root, entry)

	_update_summary()


func _passes_filters(entry: Checkable) -> bool:
	if _lesson_filter > 0 and entry.lesson != _lesson_filter:
		return false
	if _only_problems and not _store.is_flagged(category, entry.text):
		return false
	if _only_missing_sounds and not entry.has_missing_sound():
		return false
	if not _search.is_empty() and not entry.text.to_lower().contains(_search):
		return false
	return true


func _add_row(root: TreeItem, entry: Checkable) -> void:
	var item: TreeItem = _tree.create_item(root)
	_shown_count += 1
	item.set_metadata(COLUMN_TEXT, entry)

	item.set_text(COLUMN_LESSON, str(entry.lesson) if entry.lesson > 0 else "—")
	item.set_text_alignment(COLUMN_LESSON, HORIZONTAL_ALIGNMENT_CENTER)
	item.set_custom_color(COLUMN_LESSON, MUTED_COLOR)

	item.set_text(COLUMN_TEXT, entry.text)
	item.set_tooltip_text(COLUMN_TEXT, entry.text)

	_set_up_sound_cell(item, entry)

	item.set_cell_mode(COLUMN_PROBLEM, TreeItem.CELL_MODE_CHECK)
	item.set_editable(COLUMN_PROBLEM, true)
	item.set_checked(COLUMN_PROBLEM, _store.is_flagged(category, entry.text))
	item.set_tooltip_text(COLUMN_PROBLEM, "Tick this if something is wrong with this entry")

	item.set_cell_mode(COLUMN_COMMENT, TreeItem.CELL_MODE_STRING)
	item.set_editable(COLUMN_COMMENT, true)
	item.set_text(COLUMN_COMMENT, _store.get_comment(category, entry.text))
	item.set_tooltip_text(COLUMN_COMMENT,
			"Click here and describe the problem in your own words")

	_apply_row_colour(item, entry)


func _set_up_sound_cell(item: TreeItem, entry: Checkable) -> void:
	if entry.has_sound():
		var label: String = ""
		if entry.sound_names.size() > 1:
			# A sentence is read word by word; say how many recordings that is.
			label = "%d" % entry.sound_names.size()
		item.set_text(COLUMN_SOUND, label)
		item.set_text_alignment(COLUMN_SOUND, HORIZONTAL_ALIGNMENT_RIGHT)
		item.add_button(COLUMN_SOUND, _play_icon, PLAY_BUTTON_ID, false, "Play this sound")
		if entry.has_missing_sound():
			# A sentence can be partly recorded: playable, but still incomplete.
			item.set_custom_color(COLUMN_SOUND, PROBLEM_COLOR)
			item.set_tooltip_text(COLUMN_SOUND, "%d of its recordings are missing: %s"
					% [entry.missing_sound_names.size(),
					", ".join(entry.missing_sound_names)])
		return

	item.set_text(COLUMN_SOUND,
			MISSING_SOUND_LABEL if entry.has_missing_sound() else NO_SOUND_LABEL)
	item.set_text_alignment(COLUMN_SOUND, HORIZONTAL_ALIGNMENT_CENTER)
	item.set_custom_color(COLUMN_SOUND, MISSING_COLOR)
	if entry.has_missing_sound():
		item.set_tooltip_text(COLUMN_SOUND, "This pack has no %s"
				% ", ".join(entry.missing_sound_names))


func _apply_row_colour(item: TreeItem, entry: Checkable) -> void:
	var flagged: bool = _store.is_flagged(category, entry.text)
	if flagged:
		item.set_custom_color(COLUMN_TEXT, PROBLEM_COLOR)
	else:
		item.clear_custom_color(COLUMN_TEXT)


func _update_summary() -> void:
	var total: int = _entries.size()
	var parts: PackedStringArray = PackedStringArray()
	if _shown_count == total:
		parts.append("%d entries" % total)
	else:
		parts.append("showing %d of %d entries" % [_shown_count, total])
	var reported: int = _store.count_in(category)
	if reported > 0:
		parts.append("%d reported" % reported)
	if _missing_sound_count > 0:
		parts.append("%d with a missing recording" % _missing_sound_count)
	_summary.text = "  ·  ".join(parts)


func _entry_for(item: TreeItem) -> Checkable:
	var metadata: Variant = item.get_metadata(COLUMN_TEXT)
	return metadata as Checkable


func _on_button_clicked(
		item: TreeItem,
		column: int,
		id: int,
		mouse_button_index: int) -> void:
	if column != COLUMN_SOUND or id != PLAY_BUTTON_ID:
		return
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	var entry: Checkable = _entry_for(item)
	if entry:
		play_requested.emit(entry)


func _on_item_activated() -> void:
	var item: TreeItem = _tree.get_selected()
	if item == null:
		return
	var entry: Checkable = _entry_for(item)
	if entry and entry.has_sound():
		play_requested.emit(entry)


func _on_item_edited() -> void:
	var item: TreeItem = _tree.get_edited()
	if item == null:
		return
	var entry: Checkable = _entry_for(item)
	if entry == null:
		return

	match _tree.get_edited_column():
		COLUMN_PROBLEM:
			_store.set_flagged(category, entry.text, item.is_checked(COLUMN_PROBLEM))
		COLUMN_COMMENT:
			_store.set_comment(category, entry.text, item.get_text(COLUMN_COMMENT))
			# Writing an explanation is reporting a problem, so keep the box in
			# step with the text rather than making the tester tick it as well.
			item.set_checked(COLUMN_PROBLEM, _store.is_flagged(category, entry.text))
		_:
			return

	_apply_row_colour(item, entry)
	_update_summary()
	report_changed.emit()
