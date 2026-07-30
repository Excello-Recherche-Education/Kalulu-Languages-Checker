class_name ThankYouScreen
extends MarginContainer
## Last screen: hands the tester their CSV and asks them to email it over.

signal back_requested
signal load_another_requested

const CONTACT_EMAIL: String = "contact@excellolab.org"
const EMAIL_SUBJECT: String = "Kalulu language pack report"

const MUTED_COLOR: Color = Color("8d99ae")
const ACCENT_COLOR: Color = Color("8ecae6")

var _title: Label = null
var _body: Label = null
var _delivery_note: Label = null
var _download_button: Button = null
var _mail_button: Button = null
var _back_button: Button = null

var _store: ReportStore = null
var _csv: PackedByteArray = PackedByteArray()
var _file_name: String = ""


func _ready() -> void:
	add_theme_constant_override("margin_left", 48)
	add_theme_constant_override("margin_right", 48)
	add_theme_constant_override("margin_top", 48)
	add_theme_constant_override("margin_bottom", 48)

	var centered: CenterContainer = CenterContainer.new()
	add_child(centered)

	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	column.custom_minimum_size.x = 720
	centered.add_child(column)

	_title = Label.new()
	_title.text = "Thank you!"
	_title.add_theme_font_size_override("font_size", 56)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_title)

	_body = Label.new()
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body.add_theme_font_size_override("font_size", 18)
	column.add_child(_body)

	_delivery_note = Label.new()
	_delivery_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_delivery_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_delivery_note.add_theme_color_override("font_color", MUTED_COLOR)
	column.add_child(_delivery_note)

	var email_line: Label = Label.new()
	email_line.text = "Please send the file to %s" % CONTACT_EMAIL
	email_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	email_line.add_theme_font_size_override("font_size", 20)
	email_line.add_theme_color_override("font_color", ACCENT_COLOR)
	column.add_child(email_line)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	column.add_child(buttons)

	_download_button = Button.new()
	_download_button.text = "Download the report again"
	_download_button.custom_minimum_size = Vector2(240, 48)
	_download_button.pressed.connect(_deliver_csv)
	buttons.add_child(_download_button)

	_mail_button = Button.new()
	_mail_button.text = "Write the email"
	_mail_button.custom_minimum_size = Vector2(180, 48)
	_mail_button.pressed.connect(_on_mail_pressed)
	buttons.add_child(_mail_button)

	var secondary: HBoxContainer = HBoxContainer.new()
	secondary.alignment = BoxContainer.ALIGNMENT_CENTER
	secondary.add_theme_constant_override("separation", 12)
	column.add_child(secondary)

	_back_button = Button.new()
	_back_button.text = "Back to checking"
	_back_button.pressed.connect(func () -> void: back_requested.emit())
	secondary.add_child(_back_button)

	var another: Button = Button.new()
	another.text = "Check another pack"
	another.pressed.connect(func () -> void: load_another_requested.emit())
	secondary.add_child(another)

	var note: Label = Label.new()
	note.text = "The report stays saved in this browser, so you can come back to it later."
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_color_override("font_color", MUTED_COLOR)
	column.add_child(note)


## Builds the CSV for `store` and starts the download.
func present(store: ReportStore) -> void:
	_store = store
	if not is_node_ready():
		await ready

	_csv = ReportCsv.build(store)
	_file_name = ReportCsv.file_name(store)

	var count: int = store.count()
	if count == 0:
		_title.text = "Thank you!"
		_body.text = "You did not report any problem, so there is nothing to send. "
		_body.text += "If that is a mistake, go back and tick the entries that are wrong."
		_download_button.visible = false
		_mail_button.visible = false
		_delivery_note.text = ""
		return

	_download_button.visible = true
	_mail_button.visible = true
	_body.text = "Thank you for the time you spent helping us find bugs. "
	_body.text += "Your report lists %d problem%s and has been saved as %s." % [
		count, "" if count == 1 else "s", _file_name]
	_deliver_csv()


## In a browser this offers the file as a download. On desktop there is nowhere
## to prompt, so it is written next to the user data and the path is shown.
func _deliver_csv() -> void:
	if _csv.is_empty():
		return
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(_csv, _file_name, "text/csv")
		return

	var path: String = "user://%s" % _file_name
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_delivery_note.text = "Could not write the report (%s)." % error_string(
				FileAccess.get_open_error())
		return
	file.store_buffer(_csv)
	file.close()
	_delivery_note.text = "Saved to %s" % ProjectSettings.globalize_path(path)


func _on_mail_pressed() -> void:
	var body: String = "Hello,\n\nHere is my report for the %s language pack" % _store.locale
	if not _store.pack_version.is_empty():
		body += " (version %s)" % _store.pack_version
	body += ".\nThe CSV file is attached.\n\nThank you,\n"

	OS.shell_open("mailto:%s?subject=%s&body=%s" % [
		CONTACT_EMAIL,
		_percent_encode("%s — %s" % [EMAIL_SUBJECT, _store.locale]),
		_percent_encode(body),
	])


## mailto: needs its query values percent-encoded; uri_encode leaves the few
## characters that matter here alone.
func _percent_encode(text: String) -> String:
	return text.uri_encode()
