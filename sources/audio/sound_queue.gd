class_name SoundQueue
extends AudioStreamPlayer
## Plays the sound(s) of one entry, straight out of the pack archive.
##
## A grapheme-phoneme pair, a syllable or a word has a single recording. A
## sentence has none of its own, so the game reads it word by word and this
## plays those word recordings back to back.

signal queue_started
signal queue_finished

var _archive: PackArchive = null
var _pending: Array[String] = []


func _ready() -> void:
	finished.connect(_play_next)


## Plays `sound_names` in order, replacing anything already playing.
func play_sounds(archive: PackArchive, sound_names: PackedStringArray) -> void:
	stop_all()
	if archive == null or sound_names.is_empty():
		return
	_archive = archive
	_pending.assign(sound_names)
	queue_started.emit()
	_play_next()


func stop_all() -> void:
	_pending.clear()
	if playing:
		stop()


func is_busy() -> bool:
	return playing or not _pending.is_empty()


func _play_next() -> void:
	while not _pending.is_empty():
		var sound_name: String = _pending.pop_front()
		var bytes: PackedByteArray = _archive.read_sound(sound_name)
		if bytes.is_empty():
			push_warning("SoundQueue: %s is missing from the pack" % sound_name)
			continue
		var mp3: AudioStreamMP3 = AudioStreamMP3.load_from_buffer(bytes)
		if mp3 == null:
			push_warning("SoundQueue: %s is not readable as MP3" % sound_name)
			continue
		stream = mp3
		play()
		return
	queue_finished.emit()
