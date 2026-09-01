class_name ReportStore
extends RefCounted
## Holds what the tester flagged, for one pack.
##
## Reports are written to disk on every change. Testers work through thousands
## of entries in a browser tab, and losing an afternoon of reviewing to a stray
## reload would be the fastest way to lose a tester.

signal changed

const SAVE_DIRECTORY: String = "user://reports"

## Locale of the pack being reviewed, used in the save file and CSV.
var locale: String = ""
## Pack version (contents of version.txt), recorded so the team knows which
## release a report was written against.
var pack_version: String = ""

## category -> { entry text: comment }. Presence of a text means "flagged";
## the value is the tester's explanation, which may be empty.
var _reports: Dictionary[String, Dictionary] = {}


func _init(p_locale: String = "", p_pack_version: String = "") -> void:
	locale = p_locale
	pack_version = p_pack_version


func is_flagged(category: String, text: String) -> bool:
	return _reports.has(category) and _reports[category].has(text)


func get_comment(category: String, text: String) -> String:
	if not is_flagged(category, text):
		return ""
	return str(_reports[category][text])


func set_flagged(category: String, text: String, flagged: bool) -> void:
	if flagged == is_flagged(category, text):
		return
	if flagged:
		if not _reports.has(category):
			_reports[category] = {}
		_reports[category][text] = ""
	else:
		_reports[category].erase(text)
		if _reports[category].is_empty():
			_reports.erase(category)
	_on_changed()


## Writing a comment flags the entry: a tester who types an explanation has
## clearly found a problem, whether or not they ticked the box first.
func set_comment(category: String, text: String, comment: String) -> void:
	if not is_flagged(category, text):
		if comment.is_empty():
			return
		if not _reports.has(category):
			_reports[category] = {}
	elif get_comment(category, text) == comment:
		return
	_reports[category][text] = comment
	_on_changed()


func count() -> int:
	var total: int = 0
	for category: String in _reports:
		total += _reports[category].size()
	return total


func count_in(category: String) -> int:
	if not _reports.has(category):
		return 0
	return _reports[category].size()


func clear() -> void:
	if _reports.is_empty():
		return
	_reports.clear()
	_on_changed()


## Every flagged entry, ordered by category then text, ready for the CSV.
## Each row is [category, text, comment].
func rows() -> Array[PackedStringArray]:
	var result: Array[PackedStringArray] = []
	for category: String in LanguageData.CATEGORIES:
		if not _reports.has(category):
			continue
		var texts: Array = _reports[category].keys()
		texts.sort()
		for text: String in texts:
			result.append(PackedStringArray(
					[category, text, str(_reports[category][text])]))
	return result


func save_path() -> String:
	return SAVE_DIRECTORY.path_join("%s.json" % locale)


func save() -> void:
	if locale.is_empty():
		return
	if not DirAccess.dir_exists_absolute(SAVE_DIRECTORY):
		DirAccess.make_dir_recursive_absolute(SAVE_DIRECTORY)
	var file: FileAccess = FileAccess.open(save_path(), FileAccess.WRITE)
	if file == null:
		push_warning("ReportStore: cannot save reports: %s"
				% error_string(FileAccess.get_open_error()))
		return
	file.store_string(JSON.stringify({
		"locale": locale,
		"pack_version": pack_version,
		"reports": _reports,
	}))
	file.close()
	# In a browser the user filesystem only reaches IndexedDB when it is
	# flushed, so an unflushed save would not survive a reload.
	if OS.has_feature("web"):
		JavaScriptBridge.force_fs_sync()


## Reloads what was saved for this locale, so a tester can pick up where they
## left off after closing the tab.
func load_saved() -> void:
	_reports.clear()
	if not FileAccess.file_exists(save_path()):
		return
	var file: FileAccess = FileAccess.open(save_path(), FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is not Dictionary:
		return

	var saved: Dictionary = parsed
	var saved_reports: Variant = saved.get("reports")
	if saved_reports is not Dictionary:
		return
	for category: Variant in saved_reports:
		if saved_reports[category] is not Dictionary:
			continue
		# A category the checker no longer reviews — Sentence, before its tab was
		# removed. rows() would leave it out of the CSV, so counting it here
		# would show a tester reports that never reach us.
		if not LanguageData.CATEGORIES.has(str(category)):
			continue
		var entries: Dictionary = {}
		for text: Variant in saved_reports[category]:
			entries[str(text)] = str(saved_reports[category][text])
		if not entries.is_empty():
			_reports[str(category)] = entries
	changed.emit()


func _on_changed() -> void:
	save()
	changed.emit()
