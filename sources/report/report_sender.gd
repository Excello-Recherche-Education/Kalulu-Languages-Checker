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

## **The stage name is part of the path, not only of the host.** The custom
## domains map with an empty key onto routes declared as `ANY /prod/{proxy+}`
## and `ANY /dev/{proxy+}`, so `https://api.kalulu.org/checker_report` misses
## every route and returns the gateway's own "Not Found" — it never reaches the
## Lambda. `https://api.kalulu.org/prod/checker_report` does. The backend strips
## the prefix again in `_normalize_path()`. Match `ServerManagerClass` in the
## frontend, which builds its URLs the same way.
## **Reports go to the dev stage, deliberately.** The checker is an internal
## tool for a handful of volunteers, not part of the product, so it has no
## business depending on a production deploy or adding traffic to the stack the
## game relies on. Sending a report is also the only call it makes, and the
## worst case of dev being mid-deploy is one failed send with the download still
## sitting there.
##
## The practical effect: merging and deploying **DEV** is all it takes to make
## the button work. Promoting to PROD is not required and changes nothing here.
const DEV_BASE: String = "https://dev.api.kalulu.org/dev/"
const PROD_BASE: String = "https://api.kalulu.org/prod/"
const ENDPOINT_PATH: String = "checker_report"

## Selects the production API instead, should the tool ever need to outlive dev:
## open the page as `…/index.html?api=prod`.
const PROD_SELECTOR: String = "prod"

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
			endpoint(),
			["Content-Type: application/json"],
			HTTPClient.METHOD_POST,
			JSON.stringify(payload))
	if error != OK:
		_fail("Could not reach us to send the report (%s)." % error_string(error))
		return
	_busy = true


## Where the report is posted: the dev stage, unless the page was opened with
## `?api=prod`.
static func endpoint() -> String:
	return endpoint_for(_requested_api())


## Split out from endpoint() so the choice can be tested without a browser.
##
## Only the exact word "prod" selects anything, and both addresses are constants
## here. A caller cannot supply a URL: the report is what a tester wrote, and a
## query parameter that could redirect it to someone else's server would be a
## way to collect other people's reports by sending them a link.
static func endpoint_for(selector: String) -> String:
	var base: String = PROD_BASE if selector == PROD_SELECTOR else DEV_BASE
	return base + ENDPOINT_PATH


## The `api` query parameter, or "" when there is none. Only the web build has a
## page address to read; on desktop the same choice is a command-line argument,
## so the Godot editor can reach dev too.
static func _requested_api() -> String:
	if OS.has_feature("web"):
		var search: String = str(JavaScriptBridge.eval(
				"window.location.search || ''", true))
		for pair: String in search.trim_prefix("?").split("&", false):
			if pair.begins_with("api="):
				return pair.trim_prefix("api=").to_lower()
		return ""

	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	for index: int in arguments.size():
		if arguments[index] == "--api" and index + 1 < arguments.size():
			return arguments[index + 1].to_lower()
	return ""


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
