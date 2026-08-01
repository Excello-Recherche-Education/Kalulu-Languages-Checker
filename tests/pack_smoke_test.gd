extends SceneTree
## Runs the whole pack pipeline against real archives, without any interface.
##
##   godot --headless --path . --script tests/pack_smoke_test.gd -- <pack.zip>...
##
## Reports how much of each pack resolves to a playable recording, which is
## also a quick way to see whether a pack is missing audio.

const WORK_DIRECTORY: String = "user://test_pack"

var _failures: int = 0


func _init() -> void:
	var archives: PackedStringArray = OS.get_cmdline_user_args()
	if archives.is_empty():
		push_error("Pass at least one <locale>.zip to check.")
		quit(2)
		return

	for archive_path: String in archives:
		_check_archive(archive_path)

	print("")
	if _failures == 0:
		print("All checks passed.")
	else:
		print("%d check(s) failed." % _failures)
	quit(1 if _failures > 0 else 0)


func _check_archive(archive_path: String) -> void:
	print("\n=== %s" % archive_path.get_file())

	var archive: PackArchive = PackArchive.new()
	var error: String = archive.open(archive_path, WORK_DIRECTORY)
	if not _expect(error.is_empty(), "opens: %s" % error):
		return

	print("  locale=%s  version=%s  sounds_in_pack=%d"
			% [archive.locale, archive.version, archive.sound_count])
	_expect(not archive.locale.is_empty(), "locale detected")
	_expect(archive.sound_count > 0, "pack contains recordings")

	var data: LanguageData = LanguageData.new()
	error = data.open(archive)
	if not _expect(error.is_empty(), "database opens: %s" % error):
		archive.close()
		return

	var entries: Dictionary[String, Array] = data.read_all()
	var store: ReportStore = ReportStore.new(archive.locale, archive.version)

	for category: String in LanguageData.CATEGORIES:
		var category_entries: Array = entries.get(category, [] as Array)
		var playable: int = 0
		var missing: int = 0
		var lessons: int = 0
		for entry: Checkable in category_entries:
			if entry.has_sound():
				playable += 1
			if entry.has_missing_sound():
				missing += 1
			if entry.lesson > 0:
				lessons += 1
		print("  %-9s %5d entries  %5d playable  %5d missing recording  %5d with a lesson"
				% [category, category_entries.size(), playable, missing, lessons])
		_expect(not category_entries.is_empty(), "%s is not empty" % category)

	_report_database_oddities(data)
	_check_decodes_audio(archive, entries)
	_check_report_csv(archive, entries, store)

	data.close()
	archive.close()
	_expect(not archive.is_open(), "archive closes")


## The checker hides blank and repeated entries from the tester, because there
## is nothing to listen to and nothing to say about them. They are still a fault
## in the pack, so they are named here rather than disappearing quietly.
func _report_database_oddities(data: LanguageData) -> void:
	for category: String in data.skipped:
		var detail: Dictionary = data.skipped[category]
		var repeated: PackedStringArray = detail.repeated
		var parts: PackedStringArray = PackedStringArray()
		if int(detail.blank) > 0:
			parts.append("%d blank" % detail.blank)
		if not repeated.is_empty():
			parts.append("%d repeated (%s)" % [repeated.size(), ", ".join(repeated)])
		print("  note  %s: %s — hidden from the tester" % [category, ", ".join(parts)])


## Every playable entry claims a recording; make sure one really decodes, so a
## pack of empty or corrupt MP3 files does not look fine.
func _check_decodes_audio(archive: PackArchive, entries: Dictionary[String, Array]) -> void:
	for category: String in LanguageData.CATEGORIES:
		for entry: Checkable in entries.get(category, [] as Array):
			if not entry.has_sound():
				continue
			var bytes: PackedByteArray = archive.read_sound(entry.sound_names[0])
			if not _expect(not bytes.is_empty(),
					"%s '%s' reads bytes" % [category, entry.text]):
				break
			var mp3: AudioStreamMP3 = AudioStreamMP3.load_from_buffer(bytes)
			_expect(mp3 != null and mp3.get_length() > 0.0,
					"%s '%s' decodes as MP3 (%.2fs)"
							% [category, entry.text,
							mp3.get_length() if mp3 else 0.0])
			break


func _check_report_csv(
		archive: PackArchive,
		entries: Dictionary[String, Array],
		store: ReportStore) -> void:
	# Flag one entry per category, including one with a comma and a quote in it
	# so the CSV escaping is exercised.
	for category: String in LanguageData.CATEGORIES:
		var category_entries: Array = entries.get(category, [] as Array)
		if category_entries.is_empty():
			continue
		var entry: Checkable = category_entries[0]
		store.set_flagged(category, entry.text, true)
		store.set_comment(category, entry.text,
				"the sound says \"something else\", and it is too quiet")

	_expect(store.count() == LanguageData.CATEGORIES.size(),
			"store holds one report per category (%d)" % store.count())

	var csv: PackedByteArray = ReportCsv.build(store)
	var text: String = csv.slice(3).get_string_from_utf8()
	_expect(csv[0] == 0xEF and csv[1] == 0xBB and csv[2] == 0xBF, "CSV starts with a BOM")
	_expect(text.begins_with("Locale,Category,Text,User report\r\n"), "CSV header")
	_expect(text.count("\r\n") == LanguageData.CATEGORIES.size() + 1,
			"CSV has one line per report plus the header")
	_expect(text.contains("\"the sound says \"\"something else\"\", and it is too quiet\""),
			"CSV escapes quotes and commas")
	_expect(text.contains(archive.locale), "CSV names the locale")
	_expect(ReportCsv.file_name(store).begins_with(
			"kalulu-report_%s" % archive.locale), "report file name")

	# Round-trip the saved reports the way a tester reloading the page would.
	store.save()
	var reloaded: ReportStore = ReportStore.new(archive.locale, archive.version)
	reloaded.load_saved()
	_expect(reloaded.count() == store.count(),
			"reports survive a reload (%d)" % reloaded.count())
	DirAccess.remove_absolute(store.save_path())

	print("  CSV:")
	for line: String in text.split("\r\n"):
		if not line.is_empty():
			print("    " + line)


func _expect(condition: bool, description: String) -> bool:
	if condition:
		print("    ok   %s" % description)
	else:
		_failures += 1
		print("    FAIL %s" % description)
	return condition
