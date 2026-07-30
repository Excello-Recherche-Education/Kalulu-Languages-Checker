class_name LanguageData
extends RefCounted
## Reads a pack's language.db and turns it into the four lists of entries the
## tester reviews.
##
## language.db is the source of truth, not the CSV exports shipped next to it:
## some packs have been released with empty words_list.csv / syllables_list.csv,
## which would silently hide thousands of entries from the tester.

const CATEGORY_GP: String = "GP"
const CATEGORY_SYLLABLE: String = "Syllable"
const CATEGORY_WORD: String = "Word"
const CATEGORY_SENTENCE: String = "Sentence"

const CATEGORIES: Array[String] = [
	CATEGORY_GP,
	CATEGORY_SYLLABLE,
	CATEGORY_WORD,
	CATEGORY_SENTENCE,
]

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
	var word_texts: Dictionary[int, String] = _read_id_to_text("Words", "Word")

	var word_lessons: Dictionary[int, int] = _read_owner_lessons(
			"GPsInWords", "WordID", gp_lessons)
	var syllable_lessons: Dictionary[int, int] = _read_owner_lessons(
			"GPsInSyllables", "SyllableID", gp_lessons)
	var sentence_words: Dictionary[int, Array] = _read_sentence_words()

	var result: Dictionary[String, Array] = {}
	result[CATEGORY_GP] = _build_gps(gp_lessons)
	result[CATEGORY_SYLLABLE] = _build_texts(
			CATEGORY_SYLLABLE, "Syllables", "Syllable", syllable_lessons)
	result[CATEGORY_WORD] = _build_texts(
			CATEGORY_WORD, "Words", "Word", word_lessons)
	result[CATEGORY_SENTENCE] = _build_sentences(
			sentence_words, word_texts, word_lessons)
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


func _read_id_to_text(table: String, text_column: String) -> Dictionary[int, String]:
	var texts: Dictionary[int, String] = {}
	var rows: Array = _query(
			"SELECT ID, %s AS Text FROM %s" % [text_column, table])
	for row: Dictionary in rows:
		texts[int(row.ID)] = str(row.Text)
	return texts


## Sentence id -> word ids, in reading order.
func _read_sentence_words() -> Dictionary[int, Array]:
	var words: Dictionary[int, Array] = {}
	var rows: Array = _query("""
		SELECT SentenceID, WordID
		FROM WordsInSentences
		ORDER BY SentenceID, Position
	""")
	for row: Dictionary in rows:
		var sentence_id: int = int(row.SentenceID)
		if not words.has(sentence_id):
			words[sentence_id] = []
		words[sentence_id].append(int(row.WordID))
	return words


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


## A sentence has no recording of its own: the game reads it word by word, so
## the checker plays the word sounds one after the other.
func _build_sentences(
		sentence_words: Dictionary[int, Array],
		word_texts: Dictionary[int, String],
		word_lessons: Dictionary[int, int]) -> Array[Checkable]:
	var entries: Array[Checkable] = []
	var rows: Array = _query("SELECT ID, Sentence FROM Sentences")
	for row: Dictionary in rows:
		var sentence_id: int = int(row.ID)
		var entry: Checkable = Checkable.new()
		entry.category = CATEGORY_SENTENCE
		entry.text = str(row.Sentence)
		for word_id: int in sentence_words.get(sentence_id, [] as Array):
			entry.lesson = maxi(entry.lesson, word_lessons.get(word_id, 0))
			if not word_texts.has(word_id):
				continue
			_assign_sound(entry, PackArchive.text_sound_name(word_texts[word_id]))
		entries.append(entry)
	_sort(entries)
	return entries


## Records a sound as playable or as missing, depending on what the pack holds.
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
