extends Control
## Root of the checker: owns the pack currently open and moves between the three
## screens (get a pack, check it, send the report).

const BACKGROUND_COLOR: Color = Color("1d2433")
const DEFAULT_FONT_SIZE: int = 15
## Where language.db is unpacked to. SQLite needs a real file, so this is the
## one part of a pack that is written out.
const WORK_DIRECTORY: String = "user://pack"

var _archive: PackArchive = null
var _data: LanguageData = null
var _store: ReportStore = null

var _load_screen: LoadScreen = null
var _checker_screen: CheckerScreen = null
var _thank_you_screen: ThankYouScreen = null


func _ready() -> void:
	theme = _build_theme()

	var background: ColorRect = ColorRect.new()
	background.color = BACKGROUND_COLOR
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	_load_screen = LoadScreen.new()
	_load_screen.archive_chosen.connect(_on_archive_chosen)
	_add_screen(_load_screen)

	_checker_screen = CheckerScreen.new()
	_checker_screen.finish_requested.connect(_on_finish_requested)
	_checker_screen.load_another_requested.connect(_on_load_another_requested)
	_add_screen(_checker_screen)

	_thank_you_screen = ThankYouScreen.new()
	_thank_you_screen.back_requested.connect(
			func () -> void: _show_only(_checker_screen))
	_thank_you_screen.load_another_requested.connect(_on_load_another_requested)
	_add_screen(_thank_you_screen)

	_show_only(_load_screen)


func _exit_tree() -> void:
	_close_pack()


func _add_screen(screen: Control) -> void:
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.visible = false
	add_child(screen)


func _show_only(screen: Control) -> void:
	for candidate: Control in [_load_screen, _checker_screen, _thank_you_screen]:
		candidate.visible = candidate == screen


func _on_archive_chosen(archive_path: String) -> void:
	_load_screen.set_busy(true, "Opening the pack…")
	# Let the message reach the screen: opening the archive and reading the
	# database both block, and on a big pack that is a visible pause.
	await get_tree().process_frame
	await get_tree().process_frame

	_close_pack()

	var archive: PackArchive = PackArchive.new()
	var error: String = archive.open(archive_path, WORK_DIRECTORY)
	if not error.is_empty():
		_load_screen.show_error(error)
		return

	var data: LanguageData = LanguageData.new()
	error = data.open(archive)
	if not error.is_empty():
		archive.close()
		_load_screen.show_error(error)
		return

	var entries: Dictionary[String, Array] = data.read_all()
	var total: int = 0
	for category: String in entries:
		total += entries[category].size()
	if total == 0:
		data.close()
		archive.close()
		_load_screen.show_error(
				"This pack's database has no entries to check. It may be damaged — "
				+ "please tell us which pack you downloaded.")
		return

	_archive = archive
	_data = data
	_store = ReportStore.new(archive.locale, archive.version)
	_store.load_saved()

	_load_screen.set_busy(false, "")
	await _checker_screen.setup(archive, entries, _store)
	_show_only(_checker_screen)


func _on_finish_requested() -> void:
	_show_only(_thank_you_screen)
	await _thank_you_screen.present(_store)


func _on_load_another_requested() -> void:
	# The archive is closed but deliberately left on disk: the tester is going
	# back to the list, not throwing the pack away, and re-downloading 90 MB to
	# return to a pack they had a minute ago would be the whole problem this
	# screen exists to avoid. Switching to a different language replaces it.
	_close_pack()
	# The load screen reads what is stored when it is built, so it is built
	# again, and the pack just closed shows as ready to open rather than as
	# something to download.
	remove_child(_load_screen)
	_load_screen.queue_free()
	_load_screen = LoadScreen.new()
	_load_screen.archive_chosen.connect(_on_archive_chosen)
	_add_screen(_load_screen)
	_show_only(_load_screen)


func _close_pack() -> void:
	if _data:
		_data.close()
		_data = null
	if _archive:
		_archive.close()
		_archive = null
	_store = null


## A slightly larger base font than the default, because testers read every row
## of this interface for a long time.
func _build_theme() -> Theme:
	var built: Theme = Theme.new()
	built.default_font_size = DEFAULT_FONT_SIZE
	return built
