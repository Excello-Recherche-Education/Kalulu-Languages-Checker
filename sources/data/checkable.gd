class_name Checkable
extends RefCounted
## One entry a tester can review: a grapheme-phoneme pair, a syllable or a word,
## together with the recording the game plays for it.

## Category label, also written to the CSV report. See LanguageData.CATEGORY_*.
var category: String = ""
## Text shown to the tester and written to the CSV report ("r-R", "mono", ...).
var text: String = ""
## Lesson the entry belongs to, 0 when the pack does not say.
var lesson: int = 0
## The recording to play, relative to language_sounds/ — one name, or none when
## the pack does not carry it. Stays a list because SoundQueue plays a list.
var sound_names: PackedStringArray = PackedStringArray()
## The recording the pack should carry and does not. Exactly one of these two is
## filled: a missing recording is itself something worth reporting.
var missing_sound_names: PackedStringArray = PackedStringArray()


func has_sound() -> bool:
	return not sound_names.is_empty()


func has_missing_sound() -> bool:
	return not missing_sound_names.is_empty()
