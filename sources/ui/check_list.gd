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

## Which entries to list, by whether the pack carries their recording. Testers
## are here to listen, so the rows they cannot listen to are hidden by default —
## a missing recording is a fault for the team to fix, not for them to review.
enum AudioFilter {
	EXISTING,
	MISSING,
	ALL,
}

const COLUMN_LESSON: int = 0
const COLUMN_TEXT: int = 1
const COLUMN_SOUND: int = 2
const COLUMN_PROBLEM: int = 3
const COLUMN_COMMENT: int = 4
const COLUMN_COUNT: int = 5

const PLAY_BUTTON_ID: int = 0
## Only one button is ever added to the sound cell, so it is always index 0.
const PLAY_BUTTON_INDEX: int = 0

const MISSING_SOUND_LABEL: String = "missing"

const PROBLEM_COLOR: Color = Color("ffd166")
const MISSING_COLOR: Color = Color("ef767a")
const MUTED_COLOR: Color = Color("8d99ae")
const PLAY_COLOR: Color = Color("e8eef2")
## Already listened to. Dimmer than the rest, so what is left to hear stands out.
const PLAYED_COLOR: Color = Color("6b7688")

## Big enough to see across a long list, which the Tree's own boxes are not.
const CHECKBOX_SIZE: int = 20
const CHECKBOX_BORDER_COLOR: Color = Color("b9c6d6")
## The tick itself, cut out of the filled box: the page background colour.
const CHECKBOX_MARK_COLOR: Color = Color("1d2433")

var category: String = ""

var _entries: Array[Checkable] = []
var _store: ReportStore = null
var _tree: Tree = null
var _play_icon: Texture2D = null
var _played_icon: Texture2D = null
var _summary: Label = null
## Rows currently in the Tree, which is fewer than `_entries` when filtering.
var _shown_count: int = 0
## Entries the pack has no recording for. Fixed once the pack is open.
var _missing_sound_count: int = 0
## Texts whose recording the tester has played, so the list can show what is
## left to hear. Kept for the session only — it says nothing about the pack, so
## it is not worth saving next to the reports.
var _played: Dictionary[String, bool] = {}

# Active filters.
var _search: String = ""
var _lesson_filter: int = 0          # 0 = every lesson
var _only_problems: bool = false
var _audio_filter: AudioFilter = AudioFilter.EXISTING


func _init() -> void:
	add_theme_constant_override("separation", 6)


func _ready() -> void:
	_play_icon = Icons.play(18, PLAY_COLOR)
	_played_icon = Icons.play(18, PLAYED_COLOR)

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

	# The Tree's own tick box is small and low contrast, and it is the one thing
	# every tester has to hit and to read back across thousands of rows.
	_tree.add_theme_icon_override("unchecked",
			Icons.check_box(CHECKBOX_SIZE, false, CHECKBOX_BORDER_COLOR))
	_tree.add_theme_icon_override("checked",
			Icons.check_box(CHECKBOX_SIZE, true, PROBLEM_COLOR, CHECKBOX_MARK_COLOR))

	_tree.button_clicked.connect(_on_button_clicked)
	_tree.item_edited.connect(_on_item_edited)
	_tree.item_activated.connect(_on_item_activated)
	add_child(_tree)
	# Drawn over the Tree, so it must be added to it rather than beside it.
	_tree.add_child(TreeColumnLines.new(_tree))

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
	_played.clear()
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
		audio_filter: AudioFilter) -> void:
	_search = search.strip_edges().to_lower()
	_lesson_filter = lesson
	_only_problems = only_problems
	_audio_filter = audio_filter
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


## Selects the next listed entry that has a recording and plays it, so a tester
## can work down a list on the spacebar instead of aiming at every play button.
## Returns false at the end of the list, with nothing played.
func play_next() -> bool:
	if _tree == null:
		return false
	var root: TreeItem = _tree.get_root()
	if root == null:
		return false

	var selected: TreeItem = _tree.get_selected()
	var item: TreeItem = root.get_first_child() if selected == null \
			else selected.get_next()
	while item != null:
		var entry: Checkable = _entry_for(item)
		if entry != null and entry.has_sound():
			_tree.scroll_to_item(item, true)
			_play(item, entry)
			return true
		item = item.get_next()
	return false


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
	match _audio_filter:
		AudioFilter.EXISTING:
			if not entry.has_sound():
				return false
		AudioFilter.MISSING:
			if not entry.has_missing_sound():
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
	if not entry.has_sound():
		item.set_text(COLUMN_SOUND, MISSING_SOUND_LABEL)
		item.set_text_alignment(COLUMN_SOUND, HORIZONTAL_ALIGNMENT_CENTER)
		item.set_custom_color(COLUMN_SOUND, MISSING_COLOR)
		item.set_tooltip_text(COLUMN_SOUND, "This pack has no %s"
				% ", ".join(entry.missing_sound_names))
		return

	item.set_text_alignment(COLUMN_SOUND, HORIZONTAL_ALIGNMENT_RIGHT)
	item.add_button(COLUMN_SOUND, _play_icon, PLAY_BUTTON_ID, false, "")
	_apply_play_button(item, entry)


## A played sound gets a dimmer button, so a tester glancing down the column can
## see where they are up to — the list is thousands of rows long and they come
## back to it over several sittings.
func _apply_play_button(item: TreeItem, entry: Checkable) -> void:
	if item.get_button_count(COLUMN_SOUND) <= PLAY_BUTTON_INDEX:
		return
	var played: bool = _played.has(entry.text)
	item.set_button(COLUMN_SOUND, PLAY_BUTTON_INDEX,
			_played_icon if played else _play_icon)
	item.set_button_tooltip_text(COLUMN_SOUND, PLAY_BUTTON_INDEX,
			"Play it again — you have listened to this one" if played
			else "Play this sound")


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


## Asks for the sound and remembers that it was heard.
func _play(item: TreeItem, entry: Checkable) -> void:
	# Whatever played last is where the spacebar carries on from, so a play
	# button pressed halfway down the list has to move the selection too: a
	# click on a button leaves the selection where it was.
	_tree.set_selected(item, COLUMN_TEXT)
	if not _played.has(entry.text):
		_played[entry.text] = true
		_apply_play_button(item, entry)
	play_requested.emit(entry)


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
		_play(item, entry)


func _on_item_activated() -> void:
	var item: TreeItem = _tree.get_selected()
	if item == null:
		return
	var entry: Checkable = _entry_for(item)
	if entry and entry.has_sound():
		_play(item, entry)


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
