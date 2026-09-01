class_name CheckerScreen
extends MarginContainer
## The checking interface: one tab per category, each listing its entries with
## the sound the game plays, a box to tick and a place to explain the problem.

signal finish_requested
signal load_another_requested

const MUTED_COLOR: Color = Color("8d99ae")
const ACCENT_COLOR: Color = Color("8ecae6")
const PROBLEM_COLOR: Color = Color("ffd166")

## Redrawing the word list costs upwards of 100 ms — it is 2500 rows — so the
## search box waits for a pause in typing instead of redrawing on every letter.
## The other filters are single clicks and apply straight away.
const SEARCH_SETTLE_SECONDS: float = 0.25

var _archive: PackArchive = null
var _store: ReportStore = null
var _lists: Array[CheckList] = []

var _header: Label = null
var _counter: Label = null
var _tabs: TabContainer = null
var _search: LineEdit = null
var _lesson_select: OptionButton = null
var _only_problems: CheckBox = null
var _audio_select: OptionButton = null
var _finish_button: Button = null
var _sound_queue: SoundQueue = null
var _now_playing: Label = null
var _search_settle: Timer = null


func _ready() -> void:
	add_theme_constant_override("margin_left", 24)
	add_theme_constant_override("margin_right", 24)
	add_theme_constant_override("margin_top", 16)
	add_theme_constant_override("margin_bottom", 16)

	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	add_child(column)

	column.add_child(_build_header())
	column.add_child(_build_filters())

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_changed.connect(_on_tab_changed)
	column.add_child(_tabs)

	var footer: HBoxContainer = HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	column.add_child(footer)

	_now_playing = Label.new()
	_now_playing.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_now_playing.add_theme_color_override("font_color", MUTED_COLOR)
	footer.add_child(_now_playing)

	var hint: Label = Label.new()
	hint.text = "Spacebar plays the next sound"
	hint.add_theme_color_override("font_color", MUTED_COLOR)
	footer.add_child(hint)

	var stop_button: Button = Button.new()
	stop_button.text = "Stop sound"
	stop_button.icon = Icons.stop(16, Color("e8eef2"))
	stop_button.pressed.connect(_on_stop_pressed)
	footer.add_child(stop_button)

	_finish_button = Button.new()
	_finish_button.text = "Finish testing and send report"
	_finish_button.custom_minimum_size = Vector2(280, 44)
	_finish_button.pressed.connect(func () -> void: finish_requested.emit())
	footer.add_child(_finish_button)

	_sound_queue = SoundQueue.new()
	_sound_queue.queue_finished.connect(func () -> void: _now_playing.text = "")
	add_child(_sound_queue)


## Plays the next sound in the visible list. Testers listen to thousands of
## recordings in a row, and reaching for the mouse on each one is the slowest
## part of the job.
func _input(event: InputEvent) -> void:
	if not visible:
		return
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode != KEY_SPACE or key.get_modifiers_mask() != 0:
		return
	# A tester typing in the search box, or writing what is wrong with an entry,
	# must get a space — those fields keep the key for themselves.
	var focused: Control = get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit:
		return

	get_viewport().set_input_as_handled()
	var list: CheckList = _current_list()
	if list == null:
		return
	if not list.play_next():
		_sound_queue.stop_all()
		_now_playing.text = "End of the list — nothing left to play below."


## Fills the screen with a pack. Safe to call before or after _ready().
func setup(
		archive: PackArchive,
		entries: Dictionary[String, Array],
		store: ReportStore) -> void:
	_archive = archive
	_store = store
	if not is_node_ready():
		await ready

	_store.changed.connect(_refresh_counter)

	for child: Node in _tabs.get_children():
		child.queue_free()
	_lists.clear()

	for category: String in LanguageData.CATEGORIES:
		var list: CheckList = CheckList.new()
		var category_entries: Array[Checkable] = []
		category_entries.assign(entries.get(category, [] as Array))
		list.setup(category, category_entries, _store)
		list.play_requested.connect(_on_play_requested)
		_tabs.add_child(list)
		_lists.append(list)
		_tabs.set_tab_title(_tabs.get_tab_count() - 1,
				"%s (%d)" % [_tab_title(category), category_entries.size()])

	_header.text = "%s  ·  %s" % [
		AvailablePacks.locale_name(archive.locale), archive.locale]
	if not archive.version.is_empty():
		_header.text += "  ·  pack of %s" % archive.version
	_rebuild_lesson_filter()
	_refresh_counter()


func _build_header() -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	_header = Label.new()
	_header.add_theme_font_size_override("font_size", 20)
	_header.add_theme_color_override("font_color", ACCENT_COLOR)
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_header)

	_counter = Label.new()
	_counter.add_theme_color_override("font_color", PROBLEM_COLOR)
	row.add_child(_counter)

	var another: Button = Button.new()
	another.text = "Load another pack"
	another.pressed.connect(func () -> void: load_another_requested.emit())
	row.add_child(another)

	return row


func _build_filters() -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	_search_settle = Timer.new()
	_search_settle.one_shot = true
	_search_settle.wait_time = SEARCH_SETTLE_SECONDS
	_search_settle.timeout.connect(_apply_filters)
	add_child(_search_settle)

	_search = LineEdit.new()
	_search.placeholder_text = "Search…"
	_search.clear_button_enabled = true
	_search.custom_minimum_size.x = 240
	_search.text_changed.connect(func (_text: String) -> void: _search_settle.start())
	_search.text_submitted.connect(func (_text: String) -> void: _apply_filters())
	row.add_child(_search)

	var lesson_label: Label = Label.new()
	lesson_label.text = "Lesson"
	lesson_label.add_theme_color_override("font_color", MUTED_COLOR)
	row.add_child(lesson_label)

	_lesson_select = OptionButton.new()
	_lesson_select.custom_minimum_size.x = 120
	_lesson_select.item_selected.connect(func (_index: int) -> void: _apply_filters())
	row.add_child(_lesson_select)

	_only_problems = CheckBox.new()
	_only_problems.text = "Only what I reported"
	_only_problems.toggled.connect(func (_pressed: bool) -> void: _apply_filters())
	row.add_child(_only_problems)

	var audio_label: Label = Label.new()
	audio_label.text = "Audio"
	audio_label.add_theme_color_override("font_color", MUTED_COLOR)
	row.add_child(audio_label)

	# There is nothing to listen to on a row whose recording is missing, so those
	# are left out until the tester asks for them. The team still wants to know
	# which they are, which is what the other two choices are for.
	_audio_select = OptionButton.new()
	_audio_select.custom_minimum_size.x = 210
	_audio_select.add_item("Only existing audio files", CheckList.AudioFilter.EXISTING)
	_audio_select.add_item("Only missing audio files", CheckList.AudioFilter.MISSING)
	_audio_select.add_item("All", CheckList.AudioFilter.ALL)
	_audio_select.select(0)
	_audio_select.item_selected.connect(func (_index: int) -> void: _apply_filters())
	row.add_child(_audio_select)

	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	return row


## The tab labels use the plural wording the team uses for the categories.
func _tab_title(category: String) -> String:
	match category:
		LanguageData.CATEGORY_GP:
			return "GP"
		LanguageData.CATEGORY_SYLLABLE:
			return "Syllables"
		LanguageData.CATEGORY_WORD:
			return "Words"
	return category


## Lessons of the visible tab, so the filter only offers lessons that exist.
func _rebuild_lesson_filter() -> void:
	var selected_lesson: int = _selected_lesson()
	_lesson_select.clear()
	_lesson_select.add_item("All", 0)

	var list: CheckList = _current_list()
	if list == null:
		return
	for lesson: int in list.lessons():
		_lesson_select.add_item(str(lesson), lesson)
		if lesson == selected_lesson:
			_lesson_select.select(_lesson_select.item_count - 1)


func _selected_lesson() -> int:
	if _lesson_select == null or _lesson_select.selected < 0:
		return 0
	return _lesson_select.get_item_id(_lesson_select.selected)


func _selected_audio_filter() -> CheckList.AudioFilter:
	if _audio_select == null or _audio_select.selected < 0:
		return CheckList.AudioFilter.EXISTING
	return _audio_select.get_item_id(_audio_select.selected) as CheckList.AudioFilter


func _current_list() -> CheckList:
	var index: int = _tabs.current_tab
	if index < 0 or index >= _lists.size():
		return null
	return _lists[index]


func _apply_filters() -> void:
	# Anything that applies now makes a pending redraw from typing redundant.
	if _search_settle:
		_search_settle.stop()
	var list: CheckList = _current_list()
	if list == null:
		return
	list.set_filters(
			_search.text,
			_selected_lesson(),
			_only_problems.button_pressed,
			_selected_audio_filter())


func _on_tab_changed(_index: int) -> void:
	_rebuild_lesson_filter()
	_apply_filters()


func _on_play_requested(entry: Checkable) -> void:
	_now_playing.text = "Playing: %s" % entry.text
	_sound_queue.play_sounds(_archive, entry.sound_names)


func _on_stop_pressed() -> void:
	_sound_queue.stop_all()
	_now_playing.text = ""


func _refresh_counter() -> void:
	var total: int = _store.count()
	_counter.text = "" if total == 0 else "%d problem%s reported" % [
		total, "" if total == 1 else "s"]
	_finish_button.text = "Finish testing and send report" if total == 0 \
			else "Finish testing and send report (%d)" % total
