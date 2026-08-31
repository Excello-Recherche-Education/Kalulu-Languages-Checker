class_name PackCache
extends RefCounted
## The pack kept on this machine between visits, and which version it is.
##
## A downloaded pack is written to `user://packs/` and stays there, so a tester
## who comes back tomorrow — or who reloads the page mid-afternoon — does not
## download 90 MB again. On the web `user://` is the browser's own storage
## (IndexedDB), which is why every write is followed by a filesystem sync;
## without it the bytes never leave the page's memory and are gone with the tab.
##
## **One pack at a time, deliberately.** In a browser the whole user filesystem
## is held in memory, so keeping all five packs would mean carrying ~295 MB of
## it. Downloading a different locale therefore replaces the stored one. The
## tester loses nothing by that: reports are saved per locale by ReportStore and
## survive independently of the archive they were written against.
##
## The record is stored next to the archive rather than in the archive, because
## the pack's own `version.txt` says when the pack was *built*, and what matters
## for spotting an update is when it was last *published*. Those differ, and
## only the second one can be compared against the listing.

const DIRECTORY: String = "user://packs"
const RECORD_PATH: String = "user://packs/installed.json"
const ARCHIVE_EXTENSION: String = "zip"


## What is stored right now: {locale, file_name, version, size, path}, or {} when
## there is nothing usable.
##
## The archive is checked for real rather than trusted from the record. A
## download interrupted by a closed tab leaves a short file behind, and offering
## that as "continue with fr_FR" would fail much later as "this is not a .zip",
## by which point the cause is no longer obvious.
static func installed() -> Dictionary:
	var record: Dictionary = _read_record()
	if record.is_empty():
		return {}

	var path: String = DIRECTORY.path_join(str(record.get("file_name", "")))
	if not FileAccess.file_exists(path):
		return {}

	var expected: int = int(record.get("size", 0))
	var actual: int = _file_size(path)
	if actual <= 0 or (expected > 0 and actual != expected):
		push_warning("PackCache: %s is %d bytes, expected %d — ignoring it"
				% [path, actual, expected])
		return {}

	record["path"] = path
	return record


## Records a freshly stored pack. `version` is the listing's last-modified date,
## or "" for a pack the tester opened from their own computer — an update can
## never be offered for one of those, because there is nothing to compare.
static func record(locale: String, file_name: String, version: String, size: int) -> void:
	var file: FileAccess = FileAccess.open(RECORD_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("PackCache: cannot write %s (%s)"
				% [RECORD_PATH, error_string(FileAccess.get_open_error())])
		return
	file.store_string(JSON.stringify({
		"locale": locale,
		"file_name": file_name,
		"version": version,
		"size": size,
	}))
	file.close()
	sync()


## Removes every archive and the record. Called before storing a new pack, to
## keep the one-at-a-time rule.
static func clear() -> void:
	var directory: DirAccess = DirAccess.open(DIRECTORY)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		if file_name.get_extension().to_lower() == ARCHIVE_EXTENSION:
			directory.remove(file_name)
	if FileAccess.file_exists(RECORD_PATH):
		directory.remove(RECORD_PATH.get_file())
	sync()


static func ensure_directory() -> Error:
	if DirAccess.dir_exists_absolute(DIRECTORY):
		return OK
	return DirAccess.make_dir_recursive_absolute(DIRECTORY)


static func path_for(file_name: String) -> String:
	return DIRECTORY.path_join(file_name)


## Pushes the user filesystem to IndexedDB. A no-op off the web, where writes
## already landed on a real disk.
static func sync() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.force_fs_sync()


## True when `pack` (from AvailablePacks) is a newer publication than what is
## stored. Both versions must be known: an unknown one on either side means the
## question cannot be answered, and claiming an update in that case would send
## the tester through a 90 MB download for nothing.
static func is_outdated(stored: Dictionary, pack: Dictionary) -> bool:
	var stored_version: String = str(stored.get("version", ""))
	var available_version: String = str(pack.get("version", ""))
	if stored_version.is_empty() or available_version.is_empty():
		return false
	return stored_version != available_version


static func _read_record() -> Dictionary:
	if not FileAccess.file_exists(RECORD_PATH):
		return {}
	var file: FileAccess = FileAccess.open(RECORD_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is not Dictionary:
		return {}
	var record: Dictionary = parsed
	if str(record.get("file_name", "")).is_empty():
		return {}
	return record


static func _file_size(path: String) -> int:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size: int = file.get_length()
	file.close()
	return size
