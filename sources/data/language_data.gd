class_name LanguageData
extends RefCounted
## Reads a pack's language.db and turns it into the three lists of entries the
## tester reviews.
##
## Sentences are deliberately absent: a sentence has no recording of its own —
## the game reads it word by word — so there is never anything to listen to, and
## every word it is made of is already reviewed in the Words list.
##
## language.db is the source of truth, not the CSV exports shipped next to it:
## some packs have been released with empty words_list.csv / syllables_list.csv,
## which would silently hide thousands of entries from the tester.

const CATEGORY_GP: String = "GP"
const CATEGORY_SYLLABLE: String = "Syllable"
const CATEGORY_WORD: String = "Word"

const CATEGORIES: Array[String] = [
	CATEGORY_GP,
	CATEGORY_SYLLABLE,
	CATEGORY_WORD,
]

## What read_all() left out, per category: {"blank": int, "repeated": [text…]}.
## Nothing in the interface shows this — a tester has nothing to say about a
## blank or repeated entry — but it is a real fault in a pack, so it is kept
## where the team's checks can print it.
var skipped: Dictionary[String, Dictionary] = {}

var _db: SQLite = null
var _archive: PackArchive = null


## Opens the database extracted by `archive`. Returns "" on success, or a
## message to show the tester.
func open(archive: PackArchive) -> String:
	close()
	_archive = archive

	_db = SQLite.new()
	_db.path = archive.db_path
	_db.read_only = true
	if not _db.open_db():
		var message: String = _db.get_error_message()
		_db = null
		return "Could not read the language database in this pack (%s)." % message
	return ""


func close() -> void:
	if _db:
		_db.close_db()
		_db = null
	_archive = null


## Reads every category. Returns category name -> Array[Checkable].
func read_all() -> Dictionary[String, Array]:
	var gp_lessons: Dictionary[int, int] = _read_gp_lessons()
	var word_lessons: Dictionary[int, int] = _read_owner_lessons(
			"GPsInWords", "WordID", gp_lessons)
	var syllable_lessons: Dictionary[int, int] = _read_owner_lessons(
			"GPsInSyllables", "SyllableID", gp_lessons)

	skipped.clear()
	var result: Dictionary[String, Array] = {}
	result[CATEGORY_GP] = _reviewable(CATEGORY_GP, _build_gps(gp_lessons))
	result[CATEGORY_SYLLABLE] = _reviewable(CATEGORY_SYLLABLE, _build_texts(
			CATEGORY_SYLLABLE, "Syllables", "Syllable", syllable_lessons))
	result[CATEGORY_WORD] = _reviewable(CATEGORY_WORD, _build_texts(
			CATEGORY_WORD, "Words", "Word", word_lessons))
	return result


## Drops what a tester cannot act on: entries with no text, and repeats of a
## text already in the list. Real packs carry both.
##
## Dropping repeats also keeps one row per report. A report is filed against the
## text, so two rows sharing a text would share one report, and ticking one
## would leave the other looking untouched.
func _reviewable(category: String, entries: Array[Checkable]) -> Array[Checkable]:
	var seen: Dictionary[String, bool] = {}
	var result: Array[Checkable] = []
	var blank: int = 0
	var repeated: PackedStringArray = PackedStringArray()

	for entry: Checkable in entries:
		if entry.text.strip_edges().is_empty():
			blank += 1
			continue
		if seen.has(entry.text):
			repeated.append(entry.text)
			continue
		seen[entry.text] = true
		result.append(entry)

	if blank > 0 or not repeated.is_empty():
		skipped[category] = {"blank": blank, "repeated": repeated}
	return result


func _query(sql: String) -> Array:
	if _db == null:
		return []
	if not _db.query(sql):
		push_warning("LanguageData: query failed: %s" % _db.get_error_message())
		return []
	return _db.query_result


## GP id -> number of the lesson that introduces it.
func _read_gp_lessons() -> Dictionary[int, int]:
	var lessons: Dictionary[int, int] = {}
	var rows: Array = _query("""
		SELECT GPsInLessons.GPID AS GPID, MIN(Lessons.LessonNb) AS LessonNb
		FROM GPsInLessons
		INNER JOIN Lessons ON Lessons.ID = GPsInLessons.LessonID
		GROUP BY GPsInLessons.GPID
	""")
	for row: Dictionary in rows:
		lessons[int(row.GPID)] = int(row.LessonNb)
	return lessons


## Lesson at which a word or syllable becomes readable: the last lesson among
## the grapheme-phoneme pairs it is made of. Matches what the game does.
func _read_owner_lessons(
		table: String,
		owner_column: String,
		gp_lessons: Dictionary[int, int]) -> Dictionary[int, int]:
	var lessons: Dictionary[int, int] = {}
	var rows: Array = _query(
			"SELECT %s AS OwnerID, GPID FROM %s" % [owner_column, table])
	for row: Dictionary in rows:
		var owner_id: int = int(row.OwnerID)
		var gp_lesson: int = gp_lessons.get(int(row.GPID), 0)
		lessons[owner_id] = maxi(lessons.get(owner_id, 0), gp_lesson)
	return lessons


func _build_gps(gp_lessons: Dictionary[int, int]) -> Array[Checkable]:
	var entries: Array[Checkable] = []
	var rows: Array = _query("SELECT ID, Grapheme, Phoneme FROM GPs")
	for row: Dictionary in rows:
		var entry: Checkable = Checkable.new()
		entry.category = CATEGORY_GP
		entry.text = str(row.Grapheme) + "-" + str(row.Phoneme)
		entry.lesson = gp_lessons.get(int(row.ID), 0)
		_assign_sound(entry, PackArchive.gp_sound_name(
				str(row.Grapheme), str(row.Phoneme)))
		entries.append(entry)
	_sort(entries)
	return entries


func _build_texts(
		category: String,
		table: String,
		text_column: String,
		lessons: Dictionary[int, int]) -> Array[Checkable]:
	var entries: Array[Checkable] = []
	var rows: Array = _query(
			"SELECT ID, %s AS Text FROM %s" % [text_column, table])
	for row: Dictionary in rows:
		var text: String = str(row.Text)
		var entry: Checkable = Checkable.new()
		entry.category = category
		entry.text = text
		entry.lesson = lessons.get(int(row.ID), 0)
		_assign_sound(entry, PackArchive.text_sound_name(text))
		entries.append(entry)
	_sort(entries)
	return entries


## Records the entry's one recording as playable or as missing, depending on what
## the pack holds. Every entry has exactly one, present or not.
func _assign_sound(entry: Checkable, sound_name: String) -> void:
	if _archive and _archive.has_sound(sound_name):
		entry.sound_names.append(sound_name)
	else:
		entry.missing_sound_names.append(sound_name)


## Lesson order, then alphabetical, so a tester can work through a pack the way
## a class does. Entries with no lesson come last.
func _sort(entries: Array[Checkable]) -> void:
	entries.sort_custom(func (a: Checkable, b: Checkable) -> bool:
		var a_lesson: int = a.lesson if a.lesson > 0 else 1 << 30
		var b_lesson: int = b.lesson if b.lesson > 0 else 1 << 30
		if a_lesson != b_lesson:
			return a_lesson < b_lesson
		return a.text.filenocasecmp_to(b.text) < 0
	)
