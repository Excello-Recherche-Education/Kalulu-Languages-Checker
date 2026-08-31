class_name ThankYouScreen
extends MarginContainer
## Last screen: offers to send the tester's report for them, and to hand them the
## CSV if they would rather send it themselves.
##
## Nothing is downloaded on arrival. A tester who intends to press "Send my
## report" has no use for a file, and dropping one in their downloads folder
## unasked invites them to email a copy of something we already have. The
## download is one button away and every failure path points back at it.

signal back_requested
signal load_another_requested

## Where a report goes. Not the same as the load screen's contact address, which
## is for a tester whose tool is broken rather than for the report itself.
const REPORT_EMAIL: String = "developer@excellolab.org"
const EMAIL_SUBJECT: String = "Kalulu language pack report"

const MUTED_COLOR: Color = Color("8d99ae")
const ACCENT_COLOR: Color = Color("8ecae6")
const SUCCESS_COLOR: Color = Color("95d5b2")
const ERROR_COLOR: Color = Color("ef767a")

var _title: Label = null
var _body: Label = null
var _delivery_note: Label = null
var _download_button: Button = null
var _reveal_button: Button = null
var _mail_button: Button = null
var _back_button: Button = null

var _send_section: VBoxContainer = null
var _name_field: LineEdit = null
var _email_field: LineEdit = null
var _send_button: Button = null
var _send_status: Label = null
var _sender: ReportSender = null
var _manual_heading: Label = null

var _store: ReportStore = null
var _csv: PackedByteArray = PackedByteArray()
var _file_name: String = ""
## Where the report was written, on the platforms that write it to a folder.
## Empty in a browser, where the file goes wherever downloads go.
var _saved_path: String = ""
## Whether the tester has actually been handed the file yet. False on arrival,
## since the report is no longer delivered before it is asked for.
var _delivered: bool = false


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

	column.add_child(_build_send_section())

	_manual_heading = Label.new()
	_manual_heading.text = "…or send it yourself, to %s" % REPORT_EMAIL
	_manual_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_manual_heading.add_theme_font_size_override("font_size", 18)
	_manual_heading.add_theme_color_override("font_color", ACCENT_COLOR)
	column.add_child(_manual_heading)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	column.add_child(buttons)

	_download_button = Button.new()
	# In a browser the file is downloaded; everywhere else it is written to a
	# folder, and calling that "downloading" would send the tester looking in
	# the wrong place.
	_download_button.text = "Download the report" if OS.has_feature("web") \
			else "Save the report"
	_download_button.custom_minimum_size = Vector2(240, 48)
	_download_button.pressed.connect(_deliver_csv)
	buttons.add_child(_download_button)

	_reveal_button = Button.new()
	_reveal_button.text = "Show me the file"
	_reveal_button.custom_minimum_size = Vector2(180, 48)
	_reveal_button.visible = false
	_reveal_button.pressed.connect(_on_reveal_pressed)
	buttons.add_child(_reveal_button)

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
	note.text = "The report stays saved %s, so you can come back to it later." % (
			"in this browser" if OS.has_feature("web") else "on this computer")
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_color_override("font_color", MUTED_COLOR)
	column.add_child(note)


## The one-press route: the report goes straight to the team.
##
## The name and address are asked for rather than required. Without them a
## report arrives anonymous and cannot be followed up, which is a real loss when
## an entry is ambiguous — but requiring them would mean collecting personal
## details from every volunteer to file a bug, and that is the worse trade. The
## note under the fields says plainly what they are for.
func _build_send_section() -> VBoxContainer:
	_send_section = VBoxContainer.new()
	_send_section.add_theme_constant_override("separation", 8)

	var heading: Label = Label.new()
	heading.text = "Send it to us"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 20)
	heading.add_theme_color_override("font_color", ACCENT_COLOR)
	_send_section.add_child(heading)

	var fields: HBoxContainer = HBoxContainer.new()
	fields.alignment = BoxContainer.ALIGNMENT_CENTER
	fields.add_theme_constant_override("separation", 12)
	_send_section.add_child(fields)

	_name_field = LineEdit.new()
	_name_field.placeholder_text = "Your name (optional)"
	_name_field.custom_minimum_size = Vector2(260, 40)
	fields.add_child(_name_field)

	_email_field = LineEdit.new()
	_email_field.placeholder_text = "Your email (optional)"
	_email_field.custom_minimum_size = Vector2(260, 40)
	# Enter in either field sends, which is what a form conditions people to.
	_name_field.text_submitted.connect(func (_text: String) -> void: _on_send_pressed())
	_email_field.text_submitted.connect(func (_text: String) -> void: _on_send_pressed())
	fields.add_child(_email_field)

	var send_row: HBoxContainer = HBoxContainer.new()
	send_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_send_section.add_child(send_row)

	_send_button = Button.new()
	_send_button.text = "Send my report"
	_send_button.custom_minimum_size = Vector2(240, 48)
	_send_button.pressed.connect(_on_send_pressed)
	send_row.add_child(_send_button)

	var privacy: Label = Label.new()
	privacy.text = ("Only the report is sent — never the pack, and nothing else from "
			+ "your computer. Your name and address are optional, and are used to "
			+ "reply to you about this report and nothing else.")
	privacy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	privacy.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	privacy.add_theme_color_override("font_color", MUTED_COLOR)
	_send_section.add_child(privacy)

	_send_status = Label.new()
	_send_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_send_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_send_status.custom_minimum_size.y = 24
	_send_section.add_child(_send_status)

	_sender = ReportSender.new()
	_sender.sent.connect(_on_sent)
	_sender.failed.connect(_on_send_failed)
	add_child(_sender)

	return _send_section


func _on_send_pressed() -> void:
	if _csv.is_empty() or _sender.is_busy():
		return
	_send_button.disabled = true
	_send_status.remove_theme_color_override("font_color")
	_send_status.text = "Sending…"
	_sender.send(_store, _csv, _name_field.text, _email_field.text)


func _on_sent() -> void:
	_send_button.disabled = false
	_send_button.text = "Send it again"
	_send_status.add_theme_color_override("font_color", SUCCESS_COLOR)
	_send_status.text = "Sent — thank you. There is nothing else to do."


## The download is deliberately left in place and pointed at: a failure here is
## the one moment the tester is most likely to close the tab believing the work
## is gone.
func _on_send_failed(message: String) -> void:
	_send_button.disabled = false
	_send_status.add_theme_color_override("font_color", ERROR_COLOR)
	_send_status.text = "%s Your report is still saved, and the buttons below still work." % message


## Builds the CSV for `store` and shows the ways of getting it to us. The report
## is held in memory only: nothing is written or downloaded until the tester asks
## for it.
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
		_reveal_button.visible = false
		_mail_button.visible = false
		_send_section.visible = false
		_manual_heading.visible = false
		_delivery_note.text = ""
		return

	_download_button.visible = true
	_mail_button.visible = true
	# Both belong to a file that does not exist yet: _deliver_csv() is what
	# creates it and what makes these meaningful, and the tester has to ask.
	# Reset them here too, or coming back a second time shows the first visit's
	# path over a report that has since changed.
	_reveal_button.visible = false
	_delivery_note.text = ""
	_saved_path = ""
	_delivered = false
	# Reset rather than reuse: the tester may have come back from "Back to
	# checking" having flagged more entries, and a stale "Sent — thank you"
	# above a newer report would be a lie.
	_send_section.visible = true
	_manual_heading.visible = true
	_send_button.disabled = false
	_send_button.text = "Send my report"
	_send_status.remove_theme_color_override("font_color")
	_send_status.text = ""
	_body.text = "Thank you for the time you spent helping us find bugs. "
	_body.text += "Your report lists %d problem%s. Send it below, or take the " % [
		count, "" if count == 1 else "s"]
	_body.text += "file and email it yourself — whichever you prefer."


## In a browser this offers the file as a download. On desktop there is nowhere
## to prompt, so it is written next to the user data and the path is shown.
func _deliver_csv() -> void:
	if _csv.is_empty():
		return
	_delivered = true
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(_csv, _file_name, "text/csv")
		return

	var path: String = "user://%s" % _file_name
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_saved_path = ""
		_reveal_button.visible = false
		_delivery_note.text = "Could not write the report (%s)." % error_string(
				FileAccess.get_open_error())
		return
	file.store_buffer(_csv)
	file.close()

	_saved_path = ProjectSettings.globalize_path(path)
	_reveal_button.visible = true
	_delivery_note.text = "Saved to %s" % _saved_path


## Opens the folder the report was written to, with the file itself picked out,
## so the tester does not have to go hunting for that path by hand.
func _on_reveal_pressed() -> void:
	if _saved_path.is_empty():
		return
	OS.shell_show_in_file_manager(_saved_path, true)


## Writing the email means attaching the report, so make sure the tester has it.
## Nothing is downloaded on arrival any more, so pressing this first would
## otherwise open a message announcing an attachment that does not exist. This
## counts as asking for the file, so delivering it here is not the unprompted
## download that was removed.
func _on_mail_pressed() -> void:
	if not _delivered:
		_deliver_csv()

	var body: String = "Hello,\n\nHere is my report for the %s language pack" % _store.locale
	if not _store.pack_version.is_empty():
		body += " (version %s)" % _store.pack_version
	body += ".\nThe CSV file is attached.\n\nThank you,\n"

	# mailto: carries the subject and body as query values, so both have to be
	# percent-encoded — the body has newlines in it.
	OS.shell_open("mailto:%s?subject=%s&body=%s" % [
		REPORT_EMAIL,
		("%s — %s" % [EMAIL_SUBJECT, _store.locale]).uri_encode(),
		body.uri_encode(),
	])
