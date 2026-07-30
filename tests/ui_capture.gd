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
	# Long enough for the list of downloadable packs to come back from GitHub.
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

	# Flag a few entries the way a tester would, then look at the report.
	var store: ReportStore = _main._store
	var lists: Array[CheckList] = checker._lists
	for list: CheckList in lists:
		if list._entries.is_empty():
			continue
		store.set_flagged(list.category, list._entries[0].text, true)
		store.set_comment(list.category, list._entries[0].text,
				"the recording is much too quiet, and it sounds like another word")
		list.rebuild()
	for _i: int in 10:
		await process_frame
	await _capture("04_checker_reported")

	tabs.current_tab = 3
	checker._only_missing.button_pressed = true
	for _i: int in 10:
		await process_frame
	await _capture("05_sentences_missing_filter")

	_main._on_finish_requested()
	for _i: int in 30:
		await process_frame
	await _capture("06_thank_you")

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
