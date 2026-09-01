extends SceneTree
## Walks the interface with a real pack and saves a picture of each screen, so
## the layout can be reviewed without opening the editor.
##
##   godot --path . --resolution 1280x800 --script tests/ui_capture.gd -- <pack.zip> <out dir>

var _main: Control = null
var _out: String = ""


func _init() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if arguments.size() < 2:
		push_error("Usage: --script tests/ui_capture.gd -- <pack.zip> <output directory>")
		quit(2)
		return
	var pack_path: String = arguments[0]
	_out = arguments[1]
	DirAccess.make_dir_recursive_absolute(_out)

	_main = (load("res://sources/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	# Long enough for the list of downloadable packs to come back from storage.
	for _i: int in 240:
		await process_frame

	await _capture("01_load_screen")

	# Take the path the tester's file picker would have produced.
	_main._on_archive_chosen(pack_path)
	for _i: int in 90:
		await process_frame
	await _capture("02_checker_gp")

	var checker: CheckerScreen = _main._checker_screen
	var tabs: TabContainer = checker._tabs

	tabs.current_tab = 2
	for _i: int in 10:
		await process_frame
	await _capture("03_checker_words")

	# Listen to a few the way a tester on the spacebar would, so the played and
	# unplayed play buttons can be compared.
	var words: CheckList = checker._current_list()
	for _i: int in 6:
		words.play_next()
	for _i: int in 10:
		await process_frame
	await _capture("04_checker_played")

	# Flag a few entries the way a tester would, then look at the report.
	var store: ReportStore = _main._store
	var lists: Array[CheckList] = checker._lists
	for list: CheckList in lists:
		for entry: Checkable in list._entries:
			# One the list is showing, so the flagged row is in the picture.
			if not entry.has_sound():
				continue
			store.set_flagged(list.category, entry.text, true)
			store.set_comment(list.category, entry.text,
					"the recording is much too quiet, and it sounds like another word")
			break
		list.rebuild()
	for _i: int in 10:
		await process_frame
	await _capture("05_checker_reported")

	# The entries whose recording the pack does not carry, which the list hides
	# until it is asked for them.
	checker._audio_select.select(1)
	checker._apply_filters()
	for _i: int in 10:
		await process_frame
	await _capture("06_words_missing_filter")

	_main._on_finish_requested()
	for _i: int in 30:
		await process_frame
	await _capture("07_thank_you")

	print("Saved screenshots to %s" % _out)
	quit()


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	var path: String = _out.path_join("%s.png" % name)
	var error: Error = image.save_png(path)
	if error != OK:
		push_error("Could not save %s: %s" % [path, error_string(error)])
	else:
		print("  wrote %s (%dx%d)" % [path, image.get_width(), image.get_height()])
