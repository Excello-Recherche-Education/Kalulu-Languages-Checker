class_name ReportSender
extends Node
## Sends a finished report to the team, so the tester does not have to email it.
##
## This is the only thing in the checker that talks to a server, and it is worth
## being precise about what that means. The pack is still read entirely on the
## tester's own machine and nothing about it is ever uploaded. What is sent here
## is the report itself — the entries the tester flagged and what they wrote
## about them — and only when they press the button. Their name and address are
## optional, and are used to reply to them about the report and nothing else.
##
## The endpoint mails a fixed address: the checker cannot choose a recipient, so
## neither can anyone who takes this URL out of the page. See
## `handlers/checker_report.py` in Kalulu-Backend.
##
## Sending never replaces the download. If this fails — offline, endpoint down,
## backend not deployed yet — the tester still has the CSV and the address to
## send it to, which is exactly the flow that worked before this existed.

signal sent()
signal failed(message: String)

## The production API. The report endpoint has to be live on PROD for this to
## work; until then the button reports a failure and the download still stands.
const ENDPOINT: String = "https://api.kalulu.org/checker_report"

const REQUEST_TIMEOUT_SECONDS: float = 60.0

var _request: HTTPRequest = null
var _busy: bool = false


func _ready() -> void:
	_request = HTTPRequest.new()
	# Threads are off in the web build, and HTTPRequest cannot use them there.
	_request.use_threads = false
	_request.timeout = REQUEST_TIMEOUT_SECONDS
	_request.request_completed.connect(_on_request_completed)
	add_child(_request)


func is_busy() -> bool:
	return _busy


## Sends `csv` for `store`. `name` and `email` may both be empty. Exactly one of
## `sent` or `failed` will fire.
func send(store: ReportStore, csv: PackedByteArray, name: String, email: String) -> void:
	if _busy:
		return

	var payload: Dictionary = build_payload(store, csv, name, email)
	var error: Error = _request.request(
			ENDPOINT,
			["Content-Type: application/json"],
			HTTPClient.METHOD_POST,
			JSON.stringify(payload))
	if error != OK:
		_fail("Could not reach us to send the report (%s)." % error_string(error))
		return
	_busy = true


## The body posted to the endpoint. Separate from send() so the shape can be
## checked against the handler that receives it — the two ship independently,
## and a disagreement about a field name would only show up in production.
static func build_payload(store: ReportStore, csv: PackedByteArray, name: String,
		email: String) -> Dictionary:
	var payload: Dictionary = {
		"locale": store.locale,
		# get_string_from_utf8() strips the leading byte order mark, so what is
		# posted has none even though the copy saved to disk does. The endpoint
		# puts one back before attaching — without it Excel on Windows reads the
		# file as Latin-1 and mangles every accented word, which on these packs
		# is most of them. Do not "fix" this by prepending one here: that would
		# depend on the endpoint not adding its own, and the two ship separately.
		"csv": csv.get_string_from_utf8(),
		"flagged": store.count(),
	}
	if not store.pack_version.is_empty():
		payload["pack_version"] = store.pack_version
	if not name.strip_edges().is_empty():
		payload["name"] = name.strip_edges()
	if not email.strip_edges().is_empty():
		payload["email"] = email.strip_edges()
	return payload


func _on_request_completed(
		result: int,
		response_code: int,
		_headers: PackedStringArray,
		body: PackedByteArray) -> void:
	_busy = false

	if result != HTTPRequest.RESULT_SUCCESS:
		_fail(_transfer_message(result))
		return

	if response_code == 200:
		sent.emit()
		return

	# The endpoint says why it refused, and those reasons are worth passing on:
	# "that does not look like a report" means something is wrong here, not with
	# the tester's connection.
	var detail: String = ""
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed is Dictionary:
		detail = str((parsed as Dictionary).get("error", ""))

	if response_code == 503:
		_fail("Sending is unavailable at the moment. Please email the file instead.")
	elif response_code == 413:
		_fail("This report is too large to send. Please email the file instead.")
	elif detail.is_empty():
		_fail("The report could not be sent (%d). Please email the file instead."
				% response_code)
	else:
		_fail("The report could not be sent: %s. Please email the file instead."
				% detail)


func _transfer_message(result: int) -> String:
	match result:
		HTTPRequest.RESULT_TIMEOUT:
			return "Sending timed out. Please try again, or email the file instead."
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE, \
		HTTPRequest.RESULT_CONNECTION_ERROR, HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "Could not reach us. Check your connection, or email the file instead."
		_:
			return "The report could not be sent (%d). Please email the file instead." % result


func _fail(message: String) -> void:
	_busy = false
	failed.emit(message)
