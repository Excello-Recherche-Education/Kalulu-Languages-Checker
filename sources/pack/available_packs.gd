class_name AvailablePacks
extends Node
## Lists the packs a tester can download.
##
## The list comes from the latest release of the Kalulu-Languages repository, so
## it stays right when a locale is added without anyone rebuilding this tool.
## GitHub serves that endpoint with a permissive CORS header, so the request
## works from a browser. If it fails — offline, rate limited, repository moved —
## the known locales are shown instead and the tester can still reach the
## releases page by hand.

signal listed(packs: Array[Dictionary])

const REPOSITORY: String = "Excello-Recherche-Education/Kalulu-Languages"
const RELEASES_PAGE_URL: String = "https://github.com/%s/releases" % REPOSITORY
const LATEST_RELEASE_API_URL: String = "https://api.github.com/repos/%s/releases/latest" % REPOSITORY
const ARCHIVE_EXTENSION: String = "zip"
const REQUEST_TIMEOUT_SECONDS: float = 15.0

## Shown when the release cannot be read. Locales the project ships today.
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


## Asks GitHub what the latest release contains. `listed` always fires, with
## the fallback list when the request does not work out.
func refresh() -> void:
	var error: Error = _request.request(LATEST_RELEASE_API_URL, [
		"Accept: application/vnd.github+json",
	])
	if error != OK:
		push_warning("AvailablePacks: cannot reach GitHub (%s)" % error_string(error))
		listed.emit(_fallback())


static func locale_name(locale: String) -> String:
	return LOCALE_NAMES.get(locale, locale)


static func human_size(bytes: int) -> String:
	if bytes <= 0:
		return ""
	return "%.0f MB" % (float(bytes) / (1024.0 * 1024.0))


func _on_request_completed(
		result: int,
		response_code: int,
		_headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning("AvailablePacks: GitHub answered %d (result %d)"
				% [response_code, result])
		listed.emit(_fallback())
		return

	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed is not Dictionary:
		listed.emit(_fallback())
		return

	var release: Dictionary = parsed
	var assets: Variant = release.get("assets")
	if assets is not Array:
		listed.emit(_fallback())
		return

	var packs: Array[Dictionary] = []
	for asset: Variant in assets:
		if asset is not Dictionary:
			continue
		var name: String = str((asset as Dictionary).get("name", ""))
		if name.get_extension().to_lower() != ARCHIVE_EXTENSION:
			continue
		packs.append({
			"locale": name.get_basename(),
			"file_name": name,
			"size": int((asset as Dictionary).get("size", 0)),
			"url": str((asset as Dictionary).get("browser_download_url", "")),
			"release": str(release.get("tag_name", "")),
		})

	if packs.is_empty():
		listed.emit(_fallback())
		return

	packs.sort_custom(func (a: Dictionary, b: Dictionary) -> bool:
		return str(a.locale) < str(b.locale)
	)
	listed.emit(packs)


func _fallback() -> Array[Dictionary]:
	var packs: Array[Dictionary] = []
	for locale: String in KNOWN_LOCALES:
		packs.append({
			"locale": locale,
			"file_name": "%s.%s" % [locale, ARCHIVE_EXTENSION],
			"size": 0,
			"url": RELEASES_PAGE_URL,
			"release": "",
		})
	return packs
