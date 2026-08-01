class_name PackPicker
extends Node
## Gets a language pack archive from the tester's own computer.
##
## Two ways in:
##
## - The browse button, which is the tested path. A browser only opens a file
##   dialog from inside a real click on a real HTML element, and by the time
##   Godot reports a button press the browser is no longer in that click. So
##   instead of calling the dialog ourselves, a transparent <input type="file">
##   is parked exactly on top of the Godot button and the tester clicks that.
##   Reading the picked file then has to be done by hand, a slice at a time,
##   because there is no path to hand to ZIPReader.
## - Dropping the file on the page. The engine copies it into its virtual
##   filesystem and reports the path through Window.files_dropped, so there is
##   nothing to do here beyond listening. This cannot be exercised by an
##   automated test: the engine resolves the drop with webkitGetAsEntry(), which
##   only answers for a drag that really came from the desktop.
##
## On desktop the browse button is a plain FileDialog.

signal picked(archive_path: String)
signal progress(read_bytes: int, total_bytes: int)
signal failed(message: String)

const ARCHIVE_DIRECTORY: String = "user://packs"
const ARCHIVE_EXTENSION: String = "zip"
## Read a slice at a time so a 90 MB pack never exists three times over (once
## in the browser, once in the engine, once on the virtual filesystem).
const CHUNK_SIZE: int = 8 * 1024 * 1024

const _JS_PICKER: String = """
(function () {
	if (window.__kaluluPicker) {
		window.__kaluluPicker.reset();
		return;
	}
	var input = document.createElement('input');
	input.type = 'file';
	input.accept = '.zip,application/zip';
	input.setAttribute('aria-label', 'Choose a Kalulu language pack (.zip)');
	input.style.cssText = 'position:fixed;left:0;top:0;width:0;height:0;opacity:0;z-index:100;cursor:pointer;';
	document.body.appendChild(input);

	var picker = {
		state: 'idle',
		name: '',
		size: 0,
		chunk: null,
		error: '',
		file: null,
		place: function (left, top, width, height) {
			input.style.left = left + 'px';
			input.style.top = top + 'px';
			input.style.width = width + 'px';
			input.style.height = height + 'px';
		},
		read: function (offset, length) {
			picker.state = 'reading';
			picker.chunk = null;
			picker.file.slice(offset, offset + length).arrayBuffer().then(function (buffer) {
				picker.chunk = new Uint8Array(buffer);
				picker.state = 'chunk';
			}).catch(function (error) {
				picker.error = String(error);
				picker.state = 'error';
			});
		},
		reset: function () {
			picker.state = 'idle';
			picker.file = null;
			picker.chunk = null;
			picker.error = '';
			input.value = '';
		}
	};

	input.addEventListener('change', function () {
		if (input.files && input.files.length > 0) {
			picker.file = input.files[0];
			picker.name = picker.file.name;
			picker.size = picker.file.size;
			picker.state = 'picked';
		}
	});

	window.__kaluluPicker = picker;
})();
"""

var _is_web: bool = OS.has_feature("web")
var _picker: JavaScriptObject = null
## Button the transparent browser input is parked on, while it is visible.
var _anchor: Button = null
var _file_dialog: FileDialog = null
## Where the browser input was last put, to avoid repeating the same call.
## Starts at a rectangle no layout can produce, so the first frame always
## places it: the JavaScript side outlives this node and may hold an old
## position from a previous screen.
var _placement: Rect2 = Rect2(-1.0, -1.0, -1.0, -1.0)
var _scale: float = 1.0
var _scale_window_size: Vector2i = Vector2i.ZERO

# State of a read in progress.
var _destination: FileAccess = null
var _destination_path: String = ""
var _total_bytes: int = 0
var _read_bytes: int = 0


func _ready() -> void:
	get_window().files_dropped.connect(_on_files_dropped)
	if _is_web:
		JavaScriptBridge.eval(_JS_PICKER, true)
		_picker = JavaScriptBridge.get_interface("window").__kaluluPicker
		if _picker == null:
			push_warning("PackPicker: browser file input unavailable, drag and drop only")
	set_process(false)


## Makes the browse button live. On the web the transparent input is parked on
## `anchor` and follows it; on desktop `anchor` is unused.
func set_browse_anchor(anchor: Button) -> void:
	_anchor = anchor
	set_process(_is_web and _picker != null and _anchor != null)
	if _is_web and _picker == null and _anchor != null:
		_anchor.disabled = true
		_anchor.tooltip_text = "This browser cannot open a file dialog. Drag the .zip onto the page instead."


## Called when the Godot browse button is pressed. On the web the tester's
## click already went to the browser input, so there is nothing left to do.
func browse() -> void:
	if _is_web:
		return
	if _file_dialog == null:
		_file_dialog = FileDialog.new()
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.title = "Choose a Kalulu language pack"
		_file_dialog.add_filter("*.%s" % ARCHIVE_EXTENSION, "Language pack")
		_file_dialog.use_native_dialog = true
		_file_dialog.file_selected.connect(_on_local_file_chosen)
		add_child(_file_dialog)
	_file_dialog.popup_centered_ratio(0.7)


## Path of the archive kept from a previous visit, or "" when there is none.
## Only the browse path leaves one behind: a dropped file lives in a temporary
## folder the browser throws away when the tab closes.
static func cached_archive_path() -> String:
	var directory: DirAccess = DirAccess.open(ARCHIVE_DIRECTORY)
	if directory == null:
		return ""
	for file_name: String in directory.get_files():
		if file_name.get_extension().to_lower() == ARCHIVE_EXTENSION:
			return ARCHIVE_DIRECTORY.path_join(file_name)
	return ""


static func clear_cached_archives() -> void:
	var directory: DirAccess = DirAccess.open(ARCHIVE_DIRECTORY)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		directory.remove(file_name)


func _process(_delta: float) -> void:
	_follow_anchor()
	_poll_browser()


## Keeps the transparent browser input exactly on top of the Godot button.
func _follow_anchor() -> void:
	var placement: Rect2 = Rect2()
	if _anchor and _anchor.is_visible_in_tree():
		# Control coordinates are viewport coordinates; the screen transform
		# folds in the stretch applied to the viewport, giving window pixels.
		var rect: Rect2 = get_viewport().get_screen_transform() * _anchor.get_global_rect()
		placement = Rect2(rect.position * _css_pixels_per_window_pixel(),
				rect.size * _css_pixels_per_window_pixel())

	# Crossing into JavaScript is not free, and this runs every frame.
	if placement.is_equal_approx(_placement):
		return
	_placement = placement
	_picker.place(placement.position.x, placement.position.y,
			placement.size.x, placement.size.y)


## The canvas is laid out in CSS pixels but drawn in device pixels, so the two
## coordinate systems differ by the device pixel ratio. Only recomputed when the
## window changes size: evaluating JavaScript 60 times a second to read a number
## that almost never moves is pure waste.
func _css_pixels_per_window_pixel() -> float:
	var window_size: Vector2i = DisplayServer.window_get_size()
	if window_size == _scale_window_size:
		return _scale
	_scale_window_size = window_size
	_scale = 1.0

	if window_size.x <= 0:
		return _scale
	var canvas_width: float = float(JavaScriptBridge.eval("""
		(function () {
			var canvas = document.getElementById('canvas')
					|| document.querySelector('canvas');
			return canvas ? canvas.getBoundingClientRect().width : 0;
		})();
	""", true))
	if canvas_width > 0.0:
		_scale = canvas_width / float(window_size.x)
	return _scale


func _poll_browser() -> void:
	match str(_picker.state):
		"picked":
			_begin_browser_read()
		"chunk":
			_consume_browser_chunk()
		"error":
			var message: String = str(_picker.error)
			_picker.reset()
			_fail("The browser could not read that file (%s)." % message)


func _begin_browser_read() -> void:
	var file_name: String = str(_picker.name)
	_total_bytes = int(_picker.size)
	_read_bytes = 0

	if file_name.get_extension().to_lower() != ARCHIVE_EXTENSION:
		_picker.reset()
		_fail("%s is not a .zip file. Pick the language pack archive you downloaded." % file_name)
		return
	if _total_bytes <= 0:
		_picker.reset()
		_fail("%s is empty." % file_name)
		return

	# Only one pack is kept at a time, so a tester switching packs does not
	# slowly fill up the browser's storage.
	clear_cached_archives()
	if not DirAccess.dir_exists_absolute(ARCHIVE_DIRECTORY):
		DirAccess.make_dir_recursive_absolute(ARCHIVE_DIRECTORY)

	# The name comes from the tester's computer, so it is not trusted to be a
	# well-behaved path component.
	_destination_path = ARCHIVE_DIRECTORY.path_join(
			PackArchive.sanitize_file_name(file_name.get_file()))
	_destination = FileAccess.open(_destination_path, FileAccess.WRITE)
	if _destination == null:
		_picker.reset()
		_fail("Could not store the pack in this browser (%s)."
				% error_string(FileAccess.get_open_error()))
		return

	progress.emit(0, _total_bytes)
	_picker.read(0, CHUNK_SIZE)


func _consume_browser_chunk() -> void:
	var chunk: Variant = _picker.chunk
	if not JavaScriptBridge.is_js_buffer(chunk):
		_picker.reset()
		_abort_read()
		_fail("The browser returned an unreadable chunk of the file.")
		return

	var bytes: PackedByteArray = JavaScriptBridge.js_buffer_to_packed_byte_array(chunk)
	_destination.store_buffer(bytes)
	# A pack is up to 90 MB and the browser gives this storage grudgingly, so a
	# write can fail part way through. Saying so beats handing back a truncated
	# archive that fails later as "this is not a .zip".
	var write_error: Error = _destination.get_error()
	if write_error != OK and write_error != ERR_FILE_EOF:
		_picker.reset()
		_abort_read()
		_fail("This browser ran out of room while storing the pack (%s). "
				% error_string(write_error)
				+ "Free some space for this site, or try a different browser.")
		return

	_read_bytes += bytes.size()
	progress.emit(mini(_read_bytes, _total_bytes), _total_bytes)

	if _read_bytes >= _total_bytes:
		_destination.close()
		_destination = null
		_picker.reset()
		# Persist to IndexedDB so the pack survives a reload of the page.
		JavaScriptBridge.force_fs_sync()
		picked.emit(_destination_path)
		return

	if bytes.is_empty():
		# The file ended earlier than its own reported size.
		_picker.reset()
		_abort_read()
		_fail("Only part of that file could be read (%d of %d bytes). "
				% [_read_bytes, _total_bytes]
				+ "Download the pack again and retry.")
		return

	_picker.read(_read_bytes, CHUNK_SIZE)


func _abort_read() -> void:
	if _destination:
		_destination.close()
		_destination = null
	if not _destination_path.is_empty():
		DirAccess.remove_absolute(_destination_path)
		_destination_path = ""


func _on_files_dropped(files: PackedStringArray) -> void:
	for file: String in files:
		if file.get_extension().to_lower() == ARCHIVE_EXTENSION:
			picked.emit(file)
			return
	_fail("Drop the .zip language pack you downloaded, not %s."
			% (files[0].get_file() if not files.is_empty() else "that"))


func _on_local_file_chosen(path: String) -> void:
	picked.emit(path)


func _fail(message: String) -> void:
	failed.emit(message)
