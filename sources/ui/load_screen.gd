class_name LoadScreen
extends MarginContainer
## First screen: the tester picks a language and the pack arrives by itself.
##
## Downloading is one press. The pack is fetched into the browser's own storage
## and stays there, so coming back later — or reloading the page — opens it
## again without another 90 MB. When the copy on this computer is older than the
## published one, the same button offers the update instead.
##
## Opening a .zip by hand still works and is kept below, because it is the only
## way in when the storage cannot be reached, and the only way to look at a pack
## that has not been published yet.

signal archive_chosen(archive_path: String)

const TITLE: String = "Kalulu — Language Pack Checker"
const SUBTITLE: String = "Help us find mistakes in the reading content: wrong recordings, misspelled words, sounds that do not match the text."
const CONTACT_EMAIL: String = "contact@excellolab.org"

const MUTED_COLOR: Color = Color("8d99ae")
const ERROR_COLOR: Color = Color("ef767a")
const ACCENT_COLOR: Color = Color("8ecae6")
const READY_COLOR: Color = Color("95d5b2")

var _packs_container: VBoxContainer = null
var _browse_button: Button = null
var _progress: ProgressBar = null
var _status: Label = null
var _picker: PackPicker = null
var _available: AvailablePacks = null
var _downloader: PackDownloader = null

var _packs: Array[Dictionary] = []
## What is stored on this computer, re-read whenever it may have changed.
var _installed: Dictionary = {}
## Every per-pack action button, so they can all be disabled while one is busy.
var _action_buttons: Array[Button] = []
var _busy: bool = false


func _ready() -> void:
	add_theme_constant_override("margin_left", 48)
	add_theme_constant_override("margin_right", 48)
	add_theme_constant_override("margin_top", 32)
	add_theme_constant_override("margin_bottom", 32)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var column: VBoxContainer = VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 10)
	scroll.add_child(column)

	column.add_child(_heading(TITLE, 30, Color.WHITE))
	column.add_child(_paragraph(SUBTITLE))
	column.add_child(HSeparator.new())

	column.add_child(_heading("Choose a language to check", 20, ACCENT_COLOR))
	column.add_child(_paragraph(
			"The pack downloads by itself and stays on this computer, so you can "
			+ "stop and come back to it later. Packs are large (40–90 MB), so the "
			+ "first download takes a moment."))

	_packs_container = VBoxContainer.new()
	_packs_container.add_theme_constant_override("separation", 4)
	column.add_child(_packs_container)

	_progress = ProgressBar.new()
	_progress.custom_minimum_size.y = 22
	_progress.visible = false
	column.add_child(_progress)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.y = 48
	column.add_child(_status)

	column.add_child(HSeparator.new())
	column.add_child(_heading("Already have a pack file?", 16, MUTED_COLOR))
	column.add_child(_paragraph(
			"If you were sent a .zip directly, open it here — or drag it anywhere "
			+ "onto this page. Nothing is uploaded either way: the pack is read "
			+ "here, on your own computer."))

	var actions: HBoxContainer = HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	column.add_child(actions)

	_browse_button = Button.new()
	_browse_button.text = "Choose a .zip file…"
	_browse_button.custom_minimum_size = Vector2(220, 40)
	_browse_button.pressed.connect(_on_browse_pressed)
	actions.add_child(_browse_button)

	var help: RichTextLabel = RichTextLabel.new()
	help.bbcode_enabled = true
	help.fit_content = true
	help.selection_enabled = true
	help.custom_minimum_size.y = 24
	help.text = "[color=#8d99ae]Nothing here working? Write to [/color][url=mailto:%s]%s[/url]" % [
		CONTACT_EMAIL, CONTACT_EMAIL]
	help.meta_clicked.connect(func (meta: Variant) -> void:
		OS.shell_open(str(meta))
	)
	column.add_child(help)

	_picker = PackPicker.new()
	_picker.picked.connect(_on_picked)
	_picker.progress.connect(_on_read_progress)
	_picker.failed.connect(show_error)
	add_child(_picker)
	_picker.set_browse_anchor(_browse_button)

	_downloader = PackDownloader.new()
	_downloader.progress.connect(_on_download_progress)
	_downloader.finished.connect(_on_download_finished)
	_downloader.failed.connect(_on_download_failed)
	add_child(_downloader)

	_installed = PackCache.installed()

	_available = AvailablePacks.new()
	_available.listed.connect(_on_packs_listed)
	add_child(_available)
	_available.refresh()

	# Something usable may already be stored, so the list is drawn once before
	# the network answers. A tester who is offline still gets their pack.
	_rebuild_rows()
	_status.text = "Looking for the available packs…"


func set_busy(busy: bool, message: String = "") -> void:
	_busy = busy
	_browse_button.disabled = busy
	for button: Button in _action_buttons:
		button.disabled = busy
	_status.remove_theme_color_override("font_color")
	_status.text = message


func show_error(message: String) -> void:
	_progress.visible = false
	set_busy(false)
	_status.add_theme_color_override("font_color", ERROR_COLOR)
	_status.text = message


func _on_packs_listed(packs: Array[Dictionary]) -> void:
	_packs = packs
	_installed = PackCache.installed()
	_rebuild_rows()
	if _status.text == "Looking for the available packs…":
		_status.text = ""


## Draws one row per pack. Called again whenever what is stored changes, because
## the button on every row says what pressing it would do, and that answer moves
## when a pack is downloaded or replaced.
func _rebuild_rows() -> void:
	for child: Node in _packs_container.get_children():
		_packs_container.remove_child(child)
		child.queue_free()
	_action_buttons.clear()

	var packs: Array[Dictionary] = _packs
	if packs.is_empty():
		packs = _packs_from_storage_only()

	for pack: Dictionary in packs:
		_packs_container.add_child(_pack_row(pack))


## When the listing has not arrived, a pack already on this computer is still
## worth offering — it is the whole point of keeping it.
func _packs_from_storage_only() -> Array[Dictionary]:
	if _installed.is_empty():
		return []
	return [{
		"locale": str(_installed.get("locale", "")),
		"file_name": str(_installed.get("file_name", "")),
		"size": int(_installed.get("size", 0)),
		"url": "",
		"version": str(_installed.get("version", "")),
	}]


func _pack_row(pack: Dictionary) -> HBoxContainer:
	var locale: String = str(pack.locale)
	var is_stored: bool = str(_installed.get("locale", "")) == locale
	var is_outdated: bool = is_stored and PackCache.is_outdated(_installed, pack)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var name_label: Label = Label.new()
	name_label.text = "%s   (%s)" % [AvailablePacks.locale_name(locale), locale]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var size_label: Label = Label.new()
	size_label.text = AvailablePacks.human_size(int(pack.size))
	size_label.custom_minimum_size.x = 70
	size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	size_label.add_theme_color_override("font_color", MUTED_COLOR)
	row.add_child(size_label)

	var state_label: Label = Label.new()
	state_label.custom_minimum_size.x = 150
	state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if is_outdated:
		state_label.text = "new version available"
		state_label.add_theme_color_override("font_color", ACCENT_COLOR)
	elif is_stored:
		state_label.text = "on this computer"
		state_label.add_theme_color_override("font_color", READY_COLOR)
	else:
		state_label.text = AvailablePacks.human_version(str(pack.version))
		state_label.add_theme_color_override("font_color", MUTED_COLOR)
	row.add_child(state_label)

	var action: Button = Button.new()
	action.custom_minimum_size = Vector2(130, 36)
	action.disabled = _busy
	if is_outdated:
		action.text = "Update"
	elif is_stored:
		action.text = "Open"
		action.add_theme_color_override("font_color", READY_COLOR)
	else:
		action.text = "Download"
	action.pressed.connect(func () -> void: _on_pack_action(pack, is_stored and not is_outdated))
	row.add_child(action)
	_action_buttons.append(action)

	return row


## Opens the stored pack when there is nothing to fetch, and downloads otherwise.
## `use_stored` is decided when the row is drawn rather than here, so the button
## can never do something other than what its own label promised.
func _on_pack_action(pack: Dictionary, use_stored: bool) -> void:
	if _busy:
		return

	if use_stored:
		var stored: Dictionary = PackCache.installed()
		if stored.is_empty():
			# Browser storage can be cleared from under us between the row being
			# drawn and the button being pressed.
			_installed = {}
			_rebuild_rows()
			show_error("That pack is no longer stored in this browser. Please download it again.")
			return
		archive_chosen.emit(str(stored.path))
		return

	if str(pack.get("url", "")).is_empty():
		show_error("The list of packs could not be loaded, so this one cannot be downloaded. "
				+ "Check your connection and reload the page.")
		return

	_progress.visible = true
	_progress.value = 0
	set_busy(true, "Starting the download…")
	_downloader.download(pack)


func _on_download_progress(downloaded_bytes: int, total_bytes: int) -> void:
	_progress.visible = true
	_progress.max_value = maxi(total_bytes, 1)
	_progress.value = downloaded_bytes
	if total_bytes > 0:
		set_busy(true, "Downloading… %d of %d MB" % [
			downloaded_bytes / (1024 * 1024), total_bytes / (1024 * 1024)])
	else:
		set_busy(true, "Downloading… %d MB" % (downloaded_bytes / (1024 * 1024)))


func _on_download_finished(archive_path: String) -> void:
	_progress.visible = false
	_installed = PackCache.installed()
	_rebuild_rows()
	archive_chosen.emit(archive_path)


func _on_download_failed(message: String) -> void:
	_installed = PackCache.installed()
	_rebuild_rows()
	show_error(message)


func _on_browse_pressed() -> void:
	# On the web the tester's click landed on the browser's own file input,
	# which sits on top of this button; there is nothing more to do.
	_picker.browse()


func _on_read_progress(read_bytes: int, total_bytes: int) -> void:
	_progress.visible = true
	_progress.max_value = maxi(total_bytes, 1)
	_progress.value = read_bytes
	set_busy(true, "Reading the pack… %d of %d MB" % [
		read_bytes / (1024 * 1024), total_bytes / (1024 * 1024)])


func _on_picked(archive_path: String) -> void:
	_progress.visible = false
	_installed = PackCache.installed()
	_rebuild_rows()
	archive_chosen.emit(archive_path)


func _heading(text: String, font_size: int, color: Color) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _paragraph(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", MUTED_COLOR)
	return label
