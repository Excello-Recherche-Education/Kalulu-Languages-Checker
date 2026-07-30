class_name PackArchive
extends RefCounted
## Read-only access to a Kalulu language pack archive (<locale>.zip).
##
## The archive stays open for the whole session and only `language.db` is ever
## written to disk, because SQLite needs a real file to open. Every sound is
## read straight out of the ZIP when the tester presses play. A pack carries
## 20-55 MB of audio spread over thousands of MP3 files, so extracting all of
## it would be wasteful — and in a browser the user filesystem is held in
## memory, so it would be paid for twice.

const DB_FILE_NAME: String = "language.db"
const VERSION_FILE_NAME: String = "version.txt"
const SOUNDS_DIR_NAME: String = "language_sounds"
const SOUND_EXTENSION: String = ".mp3"

## Characters the Prof Tool replaces with "_" when it writes a sound file.
## Kept in sync with Utils.INVALID_FILE_CHARS in the Kalulu frontend.
const INVALID_FILE_CHARS: Array[String] = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

## Locale of the pack, taken from the folder inside the archive (e.g. "fr_FR").
var locale: String = ""
## Contents of version.txt, an ISO 8601 timestamp. Empty when the file is absent.
var version: String = ""
## Path of the extracted language.db, valid until close() is called.
var db_path: String = ""
## Number of files found in language_sounds/.
var sound_count: int = 0

var _reader: ZIPReader = null
## Top-level folder inside the archive, "fr_FR/" — empty when files sit at the root.
var _root: String = ""
## Sound file name -> real path inside the archive. Keyed on the decomposed
## form of the name, because a pack built on macOS stores "café.mp3" with a
## combining accent while the database spells it with a precomposed one.
##
## Deliberately case sensitive. Every pack has grapheme-phoneme pairs that
## differ only in case — "e-E" against "e-e", "r-R" against "r-r" — and those
## are different sounds. Falling back to a case-insensitive match would play
## the recording of the other pair, and a tester would hear something
## plausible and pass an entry whose own recording is in fact missing.
var _sounds: Dictionary[String, String] = {}


## Opens `archive_path` and extracts language.db into `db_destination_dir`.
## Returns an empty string on success, or a message to show the tester.
func open(archive_path: String, db_destination_dir: String) -> String:
	close()

	_reader = ZIPReader.new()
	var error: Error = _reader.open(archive_path)
	if error != OK:
		_reader = null
		return "This file could not be opened as a .zip archive (%s)." % error_string(error)

	var files: PackedStringArray = _reader.get_files()
	if files.is_empty():
		close()
		return "This archive is empty."

	var db_entry: String = _find_database_entry(files)
	if db_entry.is_empty():
		close()
		return "This archive does not contain a %s file, so it is not a Kalulu language pack." % DB_FILE_NAME

	_root = db_entry.trim_suffix(DB_FILE_NAME)
	locale = _root.trim_suffix("/")
	if locale.is_empty():
		# No folder inside the archive: fall back to the file name, "fr_FR.zip".
		locale = archive_path.get_file().get_basename()

	version = _read_text(VERSION_FILE_NAME).strip_edges()
	_index_sounds(files)

	var extract_error: String = _extract_database(db_entry, db_destination_dir)
	if not extract_error.is_empty():
		close()
		return extract_error

	return ""


func close() -> void:
	if _reader:
		_reader.close()
		_reader = null
	_root = ""
	locale = ""
	version = ""
	db_path = ""
	sound_count = 0
	_sounds.clear()


func is_open() -> bool:
	return _reader != null


## Returns true when `file_name` (e.g. "r-R.mp3") exists in language_sounds/.
func has_sound(file_name: String) -> bool:
	return not _resolve_sound(file_name).is_empty()


## Returns the raw bytes of a sound, or an empty array when it is missing.
func read_sound(file_name: String) -> PackedByteArray:
	var entry: String = _resolve_sound(file_name)
	if entry.is_empty():
		return PackedByteArray()
	return _reader.read_file(entry)


## Builds the sound file name the game would look for, for a grapheme-phoneme
## pair: "<Grapheme>-<Phoneme>.mp3". Mirrors Database.get_gp_sound_path().
static func gp_sound_name(grapheme: String, phoneme: String) -> String:
	return sanitize_file_name(grapheme + "-" + phoneme) + SOUND_EXTENSION


## Sound file name for a syllable, a word or any other plain text entry:
## "<text>.mp3". Mirrors Database.get_word_sound_path().
static func text_sound_name(text: String) -> String:
	return sanitize_file_name(text) + SOUND_EXTENSION


## Applies the same substitutions the Prof Tool applies before writing a file.
static func sanitize_file_name(name: String) -> String:
	var result: String = name
	for character: String in INVALID_FILE_CHARS:
		result = result.replace(character, "_")
	return result


func _find_database_entry(files: PackedStringArray) -> String:
	# Prefer the shallowest match: a pack has exactly one language.db, but an
	# archive of several packs would have more and the first one found wins.
	var best: String = ""
	for file: String in files:
		if file != DB_FILE_NAME and not file.ends_with("/" + DB_FILE_NAME):
			continue
		if best.is_empty() or file.count("/") < best.count("/"):
			best = file
	return best


func _index_sounds(files: PackedStringArray) -> void:
	var prefix: String = _root + SOUNDS_DIR_NAME + "/"
	for file: String in files:
		if not file.begins_with(prefix) or file.ends_with("/"):
			continue
		var name: String = file.substr(prefix.length())
		# Skip the kalulu/ subfolder: those are the mascot's spoken lines, not
		# pronunciations of pack entries, so there is nothing to check there.
		if name.contains("/"):
			continue
		sound_count += 1
		var key: String = UnicodeNormalizer.to_nfd_basic(name)
		if not _sounds.has(key):
			_sounds[key] = file


func _resolve_sound(file_name: String) -> String:
	if _reader == null:
		return ""
	return _sounds.get(UnicodeNormalizer.to_nfd_basic(file_name), "")


func _read_text(file_name: String) -> String:
	var entry: String = _root + file_name
	if not _reader.file_exists(entry):
		return ""
	return _reader.read_file(entry).get_string_from_utf8()


func _extract_database(db_entry: String, destination_dir: String) -> String:
	var bytes: PackedByteArray = _reader.read_file(db_entry)
	if bytes.is_empty():
		return "The %s file inside this archive is empty." % DB_FILE_NAME

	if not DirAccess.dir_exists_absolute(destination_dir):
		var make_error: Error = DirAccess.make_dir_recursive_absolute(destination_dir)
		if make_error != OK:
			return "Could not create a working folder (%s)." % error_string(make_error)

	var destination: String = destination_dir.path_join(DB_FILE_NAME)
	var file: FileAccess = FileAccess.open(destination, FileAccess.WRITE)
	if file == null:
		return "Could not write the database to disk (%s)." % error_string(FileAccess.get_open_error())
	file.store_buffer(bytes)
	file.close()

	db_path = destination
	return ""
