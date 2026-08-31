extends SceneTree
## Exercises the download path end to end, against the real pack storage.
##
##   godot --headless --path . --script tests/download_test.gd
##   godot --headless --path . --script tests/download_test.gd -- fr_FR
##
## Lists the packs, downloads one, opens it, and checks that the version was
## recorded and that a second visit is offered the stored copy rather than
## another download. Defaults to the smallest pack, because this really does
## transfer it.
##
## This is the desktop half. It proves the listing parses, the transfer works
## and the bookkeeping is right, but it cannot prove the part that actually
## breaks in a browser — CORS, and whether the pack survives in IndexedDB. Only
## tests/web_e2e.mjs sees that.
##
## **Signal results are collected into members, never into locals captured by a
## lambda.** GDScript lambdas capture by value, so `var done := false` set from
## inside a callback stays false outside it, and the wait below would spin until
## the timeout on a request that had in fact already succeeded.

var _available: AvailablePacks = null
var _downloader: PackDownloader = null
var _wanted: String = ""
var _failures: int = 0

var _packs: Array[Dictionary] = []
var _listed: bool = false
var _settled: bool = false
var _failure: String = ""
var _archive_path: String = ""
var _last_report: int = 0

## Frames to wait before giving up. At 60 fps this is about two minutes, which
## is generous for a 41 MB transfer and short enough to fail rather than hang.
const MAX_WAIT_FRAMES: int = 7200


func _initialize() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	_wanted = arguments[0] if arguments.size() > 0 else ""
	_run()


func _run() -> void:
	# Start from nothing, so "already stored" below means this run stored it.
	PackCache.clear()

	_available = AvailablePacks.new()
	root.add_child(_available)
	_downloader = PackDownloader.new()
	root.add_child(_downloader)
	# _ready() is deferred to the first idle frame when a node is added this
	# early, so both still have a null HTTPRequest at this point.
	await process_frame

	print("Listing %s" % AvailablePacks.LIST_URL)
	# Connected rather than awaited: refresh() emits synchronously when the
	# request cannot even be started, and an await set up afterwards would miss
	# that and wait forever.
	_available.listed.connect(_on_listed)
	_available.refresh()
	if not await _wait_for(func () -> bool: return _listed):
		_fail("the listing never came back")
		return _finish()

	if _packs.is_empty():
		_fail("the listing returned nothing")
		return _finish()

	print("\n%-28s %10s  %s" % ["pack", "size", "published"])
	for pack: Dictionary in _packs:
		print("%-28s %10s  %s" % [
			"%s (%s)" % [AvailablePacks.locale_name(str(pack.locale)), pack.locale],
			AvailablePacks.human_size(int(pack.size)),
			AvailablePacks.human_version(str(pack.version))])

	# A fallback list has no sizes and no versions; it means the request failed
	# and everything below would be testing the wrong thing.
	if int(_packs[0].size) <= 0 or str(_packs[0].version).is_empty():
		_fail("got the offline fallback list, not the real one — is the bucket reachable?")
		return _finish()

	var chosen: Dictionary = _pick(_packs)
	print("\nDownloading %s (%s)…" % [chosen.locale, AvailablePacks.human_size(int(chosen.size))])

	_downloader.progress.connect(_on_progress)
	# Exactly one of the two fires, so waiting on `finished` alone would hang on
	# every failure — including the ones this test exists to catch.
	_downloader.finished.connect(_on_finished)
	_downloader.failed.connect(_on_failed)
	_downloader.download(chosen)
	if not await _wait_for(func () -> bool: return _settled):
		_fail("the download neither finished nor failed")
		return _finish()

	if not _failure.is_empty():
		_fail("download failed: %s" % _failure)
		return _finish()

	_check("the archive is on disk", FileAccess.file_exists(_archive_path))

	var stored: Dictionary = PackCache.installed()
	_check("the pack was recorded", not stored.is_empty())
	_check("the recorded locale is %s" % chosen.locale,
			str(stored.get("locale", "")) == str(chosen.locale))
	_check("the recorded version is the published one",
			str(stored.get("version", "")) == str(chosen.version))
	_check("the recorded size is the published one",
			int(stored.get("size", 0)) == int(chosen.size))

	# The point of recording a version: coming back tomorrow must not re-download
	# an unchanged pack, and must re-download a changed one.
	_check("an unchanged pack is not called outdated",
			not PackCache.is_outdated(stored, chosen))
	var newer: Dictionary = chosen.duplicate()
	newer["version"] = "2099-01-01T00:00:00.000Z"
	_check("a republished pack is called outdated", PackCache.is_outdated(stored, newer))
	var unknown: Dictionary = chosen.duplicate()
	unknown["version"] = ""
	_check("an unknown version is never called outdated",
			not PackCache.is_outdated(stored, unknown))

	# What was downloaded has to be a pack, not an error page saved to disk.
	var archive: PackArchive = PackArchive.new()
	var error: String = archive.open(_archive_path, "user://pack")
	_check("the archive opens as a pack (%s)" % error, error.is_empty())
	if error.is_empty():
		_check("it holds the %s database" % chosen.locale,
				archive.locale == str(chosen.locale))
		_check("it holds recordings (%d)" % archive.sound_count, archive.sound_count > 0)
		var data: LanguageData = LanguageData.new()
		var data_error: String = data.open(archive)
		_check("the database opens (%s)" % data_error, data_error.is_empty())
		if data_error.is_empty():
			var entries: Dictionary[String, Array] = data.read_all()
			var total: int = 0
			for category: String in entries:
				total += entries[category].size()
			_check("it has entries to check (%d)" % total, total > 0)
			data.close()
		archive.close()

	_finish()


func _on_listed(found: Array[Dictionary]) -> void:
	_packs = found
	_listed = true


func _on_progress(downloaded: int, total: int) -> void:
	# Every frame is far too much output for a 41 MB transfer.
	if downloaded - _last_report < 8 * 1024 * 1024:
		return
	_last_report = downloaded
	print("  %d / %d MB" % [downloaded / (1024 * 1024), total / (1024 * 1024)])


func _on_finished(path: String) -> void:
	_archive_path = path
	_settled = true


func _on_failed(message: String) -> void:
	_failure = message
	_settled = true


## Spins until `condition` holds, or gives up. Returns whether it held.
func _wait_for(condition: Callable) -> bool:
	var frames: int = 0
	while not condition.call():
		if frames >= MAX_WAIT_FRAMES:
			return false
		frames += 1
		await process_frame
	return true


func _pick(packs: Array[Dictionary]) -> Dictionary:
	if not _wanted.is_empty():
		for pack: Dictionary in packs:
			if str(pack.locale) == _wanted:
				return pack
		print("No pack named %s; using the smallest instead." % _wanted)

	var smallest: Dictionary = packs[0]
	for pack: Dictionary in packs:
		if int(pack.size) < int(smallest.size):
			smallest = pack
	return smallest


func _check(what: String, passed: bool) -> void:
	print("  %s  %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1


func _fail(message: String) -> void:
	print("  FAIL  %s" % message)
	_failures += 1


func _finish() -> void:
	if _failures == 0:
		print("\nAll checks passed.")
	else:
		print("\n%d check(s) failed." % _failures)
	quit(1 if _failures > 0 else 0)
