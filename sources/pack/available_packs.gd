class_name AvailablePacks
extends Node
## Lists the packs a tester can download, and says which version each one is.
##
## The list is read from the `Languages-Checker/` folder of the S3 bucket that
## already holds the packs the game itself downloads. Listing that folder gives
## the locale, the size and the last-modified date of every pack in one request,
## so adding a locale is a pure upload — nothing here needs changing and nothing
## needs rebuilding.
##
## ## Why not GitHub releases
##
## This used to read the latest Kalulu-Languages release, and the tester had to
## download the .zip by hand and open it. That is not a stylistic choice that
## can simply be reversed: **GitHub sends no `Access-Control-Allow-Origin` on
## release assets**, neither on the github.com redirect nor on the
## release-assets.githubusercontent.com blob it points at. A browser therefore
## refuses to hand the bytes to this page, and Godot's web HTTPRequest is XHR
## underneath, so it is bound by exactly the same rule. The game gets away with
## it because it is a native build, where CORS does not exist.
##
## The S3 folder is public precisely so this works: anonymous GetObject on
## `Languages-Checker/*`, anonymous ListBucket scoped to that same prefix, and a
## CORS rule that lets a browser read the result. Nothing else in the bucket is
## public — the packs the game downloads still need a presigned URL, and asking
## for them anonymously returns 403.
##
## A CORS rule is not what makes the folder readable, and adding one elsewhere
## would not open anything: it only permits a browser to hand the page a
## response it was already allowed to receive.

signal listed(packs: Array[Dictionary])

const BUCKET_URL: String = "https://kalulu-app-language-packs.s3.eu-west-3.amazonaws.com"
const PREFIX: String = "Languages-Checker/"
const LIST_URL: String = "%s/?list-type=2&prefix=%s" % [BUCKET_URL, PREFIX]
const ARCHIVE_EXTENSION: String = "zip"
const REQUEST_TIMEOUT_SECONDS: float = 15.0

## Used to build the list when the bucket cannot be reached. The pack addresses
## are predictable, so a tester who is merely rate limited or behind a flaky
## connection can still download — they just do not get sizes or versions, and
## so cannot be told when an update exists.
const KNOWN_LOCALES: Array[String] = ["fr_FR", "es_AR", "es_CO", "es_UY", "pt_BR"]

## Human readable names, so a tester picks a language rather than a code.
const LOCALE_NAMES: Dictionary[String, String] = {
	"fr_FR": "French (France)",
	"es_AR": "Spanish (Argentina)",
	"es_CO": "Spanish (Colombia)",
	"es_UY": "Spanish (Uruguay)",
	"pt_BR": "Portuguese (Brazil)",
}

var _request: HTTPRequest = null


func _ready() -> void:
	_request = HTTPRequest.new()
	# Threads are off in the web build, and HTTPRequest cannot use them there.
	_request.use_threads = false
	_request.timeout = REQUEST_TIMEOUT_SECONDS
	_request.request_completed.connect(_on_request_completed)
	add_child(_request)


## Asks the bucket what it holds. `listed` always fires, with the fallback list
## when the request does not work out.
func refresh() -> void:
	var error: Error = _request.request(LIST_URL)
	if error != OK:
		push_warning("AvailablePacks: cannot reach the pack storage (%s)" % error_string(error))
		listed.emit(_fallback())


static func locale_name(locale: String) -> String:
	return LOCALE_NAMES.get(locale, locale)


static func human_size(bytes: int) -> String:
	if bytes <= 0:
		return ""
	return "%.0f MB" % (float(bytes) / (1024.0 * 1024.0))


## Turns "2026-08-31T12:32:32.000Z" into "31 Aug 2026", for a tester who wants to
## know how old the pack they are about to review is. Returns "" for anything
## that is not a date, so a missing version never shows as a broken one.
static func human_version(version: String) -> String:
	if version.length() < 10:
		return ""
	var parts: PackedStringArray = version.substr(0, 10).split("-")
	if parts.size() != 3:
		return ""
	const MONTHS: Array[String] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
			"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var month: int = int(parts[1])
	if month < 1 or month > 12:
		return ""
	return "%d %s %s" % [int(parts[2]), MONTHS[month - 1], parts[0]]


func _on_request_completed(
		result: int,
		response_code: int,
		_headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning("AvailablePacks: the pack storage answered %d (result %d)"
				% [response_code, result])
		listed.emit(_fallback())
		return

	var packs: Array[Dictionary] = _parse_listing(body)
	if packs.is_empty():
		listed.emit(_fallback())
		return

	packs.sort_custom(func (a: Dictionary, b: Dictionary) -> bool:
		return str(a.locale) < str(b.locale)
	)
	listed.emit(packs)


## Reads an S3 ListObjectsV2 response. Only <Contents> children are of interest:
## <Key>, <Size> and <LastModified>, which together are everything the tester is
## shown and everything needed to spot an update.
func _parse_listing(body: PackedByteArray) -> Array[Dictionary]:
	var packs: Array[Dictionary] = []
	var parser: XMLParser = XMLParser.new()
	if parser.open_buffer(body) != OK:
		return packs

	var in_contents: bool = false
	var element: String = ""
	var entry: Dictionary = {}

	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				element = parser.get_node_name()
				if element == "Contents":
					in_contents = true
					entry = {"key": "", "size": 0, "version": ""}
			XMLParser.NODE_ELEMENT_END:
				if parser.get_node_name() == "Contents":
					in_contents = false
					var pack: Dictionary = _to_pack(entry)
					if not pack.is_empty():
						packs.append(pack)
				element = ""
			XMLParser.NODE_TEXT:
				if not in_contents:
					continue
				var text: String = parser.get_node_data().strip_edges()
				match element:
					"Key": entry["key"] = text
					"Size": entry["size"] = int(text)
					"LastModified": entry["version"] = text

	return packs


## Turns one <Contents> entry into a pack, or {} when it is not one. The folder
## marker itself ("Languages-Checker/") and anything that is not a .zip are
## skipped, so a stray file next to the packs cannot show up as a language.
func _to_pack(entry: Dictionary) -> Dictionary:
	var key: String = str(entry.get("key", ""))
	if not key.begins_with(PREFIX):
		return {}
	var file_name: String = key.substr(PREFIX.length())
	if file_name.is_empty() or file_name.contains("/"):
		return {}
	if file_name.get_extension().to_lower() != ARCHIVE_EXTENSION:
		return {}

	return {
		"locale": file_name.get_basename(),
		"file_name": file_name,
		"size": int(entry.get("size", 0)),
		"url": "%s/%s%s" % [BUCKET_URL, PREFIX, file_name.uri_encode()],
		"version": str(entry.get("version", "")),
	}


func _fallback() -> Array[Dictionary]:
	var packs: Array[Dictionary] = []
	for locale: String in KNOWN_LOCALES:
		var file_name: String = "%s.%s" % [locale, ARCHIVE_EXTENSION]
		packs.append({
			"locale": locale,
			"file_name": file_name,
			"size": 0,
			"url": "%s/%s%s" % [BUCKET_URL, PREFIX, file_name],
			"version": "",
		})
	return packs
