class_name Checkable
extends RefCounted
## One entry a tester can review: a grapheme-phoneme pair, a syllable, a word
## or a sentence, together with the sound(s) the game plays for it.

## Category label, also written to the CSV report. See LanguageData.CATEGORY_*.
var category: String = ""
## Text shown to the tester and written to the CSV report ("r-R", "mono", ...).
var text: String = ""
## Lesson the entry belongs to, 0 when the pack does not say.
var lesson: int = 0
## Sound files to play, in order, relative to language_sounds/. A word has one,
## a sentence has one per word, an entry with no recording has none.
var sound_names: PackedStringArray = PackedStringArray()
## Sounds the pack should contain but does not. Shown to the tester, because a
## missing recording is itself something worth reporting.
var missing_sound_names: PackedStringArray = PackedStringArray()


func has_sound() -> bool:
	return not sound_names.is_empty()


func has_missing_sound() -> bool:
	return not missing_sound_names.is_empty()
