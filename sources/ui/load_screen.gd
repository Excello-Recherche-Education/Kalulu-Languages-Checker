class_name LoadScreen
extends MarginContainer
## First screen: tells the tester where to get a pack, then takes the file they
## downloaded.

signal archive_chosen(archive_path: String)

const TITLE: String = "Kalulu — Language Pack Checker"
const SUBTITLE: String = "Help us find mistakes in the reading content: wrong recordings, misspelled words, sounds that do not match the text."

const MUTED_COLOR: Color = Color("8d99ae")
const ERROR_COLOR: Color = Color("ef767a")
const ACCENT_COLOR: Color = Color("8ecae6")

var _packs_container: VBoxContainer = null
var _browse_button: Button = null
var _resume_button: Button = null
var _progress: ProgressBar = null
var _status: Label = null
var _picker: PackPicker = null
var _available: AvailablePacks = null


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

	column.add_child(_heading("Step 1 — Download a language pack", 20, ACCENT_COLOR))
	column.add_child(_paragraph(
			"Choose a language below to download its pack from GitHub. "
			+ "The files are large (40–90 MB), so this can take a moment."))
	_packs_container = VBoxContainer.new()
	_packs_container.add_theme_constant_override("separation", 4)
	column.add_child(_packs_container)

	var releases_link: RichTextLabel = RichTextLabel.new()
	releases_link.bbcode_enabled = true
	releases_link.fit_content = true
	releases_link.selection_enabled = true
	releases_link.custom_minimum_size.y = 24
	releases_link.text = "[color=#8d99ae]If a button does not open, copy this address into a new tab: [/color][url=%s]%s[/url]" % [
		AvailablePacks.RELEASES_PAGE_URL, AvailablePacks.RELEASES_PAGE_URL]
	releases_link.meta_clicked.connect(func (meta: Variant) -> void:
		OS.shell_open(str(meta))
	)
	column.add_child(releases_link)

	column.add_child(HSeparator.new())
	column.add_child(_heading("Step 2 — Open the pack you downloaded", 20, ACCENT_COLOR))
	column.add_child(_paragraph(
			"Drag the .zip file anywhere onto this page, or use the button below. "
			+ "Nothing is uploaded: the pack is read here, on your own computer."))

	var actions: HBoxContainer = HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	column.add_child(actions)

	_browse_button = Button.new()
	_browse_button.text = "Choose a .zip file…"
	_browse_button.custom_minimum_size = Vector2(220, 44)
	_browse_button.pressed.connect(_on_browse_pressed)
	actions.add_child(_browse_button)

	_resume_button = Button.new()
	_resume_button.custom_minimum_size = Vector2(0, 44)
	_resume_button.visible = false
	_resume_button.pressed.connect(_on_resume_pressed)
	actions.add_child(_resume_button)

	_progress = ProgressBar.new()
	_progress.custom_minimum_size.y = 22
	_progress.visible = false
	column.add_child(_progress)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.y = 48
	column.add_child(_status)

	_picker = PackPicker.new()
	_picker.picked.connect(_on_picked)
	_picker.progress.connect(_on_progress)
	_picker.failed.connect(show_error)
	add_child(_picker)
	_picker.set_browse_anchor(_browse_button)

	_available = AvailablePacks.new()
	_available.listed.connect(_on_packs_listed)
	add_child(_available)
	_available.refresh()

	_offer_cached_archive()


func set_busy(busy: bool, message: String = "") -> void:
	_browse_button.disabled = busy
	_resume_button.disabled = busy
	if not message.is_empty():
		_status.remove_theme_color_override("font_color")
		_status.text = message


func show_error(message: String) -> void:
	_progress.visible = false
	set_busy(false)
	_status.add_theme_color_override("font_color", ERROR_COLOR)
	_status.text = message


## Offers the pack from a previous visit. Only the browse path leaves one: a
## dropped file lives in a folder the browser discards with the tab.
func _offer_cached_archive() -> void:
	var cached: String = PackPicker.cached_archive_path()
	if cached.is_empty():
		return
	_resume_button.text = "Continue with %s" % cached.get_file()
	_resume_button.visible = true


func _on_packs_listed(packs: Array[Dictionary]) -> void:
	for child: Node in _packs_container.get_children():
		child.queue_free()

	for pack: Dictionary in packs:
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)

		var name_label: Label = Label.new()
		name_label.text = "%s   (%s)" % [
			AvailablePacks.locale_name(str(pack.locale)), str(pack.locale)]
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)

		var size_label: Label = Label.new()
		size_label.text = AvailablePacks.human_size(int(pack.size))
		size_label.custom_minimum_size.x = 80
		size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		size_label.add_theme_color_override("font_color", MUTED_COLOR)
		row.add_child(size_label)

		var download: Button = Button.new()
		download.text = "Download"
		download.custom_minimum_size.x = 120
		var url: String = str(pack.url)
		download.pressed.connect(func () -> void:
			OS.shell_open(url)
		)
		row.add_child(download)

		_packs_container.add_child(row)


func _on_browse_pressed() -> void:
	# On the web the tester's click landed on the browser's own file input,
	# which sits on top of this button; there is nothing more to do.
	_picker.browse()


func _on_resume_pressed() -> void:
	var cached: String = PackPicker.cached_archive_path()
	if cached.is_empty():
		_resume_button.visible = false
		show_error("That pack is no longer stored in this browser. Please open the file again.")
		return
	archive_chosen.emit(cached)


func _on_progress(read_bytes: int, total_bytes: int) -> void:
	_progress.visible = true
	_progress.max_value = maxi(total_bytes, 1)
	_progress.value = read_bytes
	set_busy(true, "Reading the pack… %d of %d MB" % [
		read_bytes / (1024 * 1024), total_bytes / (1024 * 1024)])


func _on_picked(archive_path: String) -> void:
	_progress.visible = false
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
