# Kalulu-Languages-Checker — Guide for Claude

## Role

A web tool for volunteer testers to review the contents of a Kalulu language
pack and report data problems: mispronounced or wrong recordings, misspelled
text, missing audio. Output is a CSV the tester emails to
`contact@excellolab.org`.

Read `README.md` first — it explains the tester's journey and the reasoning
behind the design. This file covers only what is easy to get wrong.

## Technology

- **Engine**: Godot 4.7.1 (GDScript)
- **Target**: Web, single-threaded, GDExtension support on
- **SQLite**: `godot-sqlite` 4.7, vendored in `addons/`
- **No backend.** Packs come from Kalulu-Languages GitHub releases, downloaded
  by the tester and opened locally. There is no API, no account, no upload.

## Things that will bite you

- **`language.db` is the source of truth, never the CSV exports** next to it in
  the pack. Released packs exist with empty `words_list.csv` and
  `syllables_list.csv` (`es_CO` is missing 1622 words and 240 syllables from its
  exports). Reading the CSVs would hide most of a pack from the tester.
- **Sound lookups are case sensitive on purpose.** Every pack has entries that
  differ only in case — `e-E`/`e-e`, `o-O`/`o-o`, `r-R`/`r-r` — and those are
  different sounds. Do not add a case-insensitive fallback: it would serve the
  other entry's recording, and a tester would pass an entry whose recording is
  actually missing. See `PackArchive._sounds`.
- **Names are matched on their decomposed form.** Packs built on macOS store
  `café.mp3` with a combining accent, the database spells it precomposed.
  `UnicodeNormalizer` handles it and is a copy of the frontend's file — keep the
  two in sync.
- **Sound file naming mirrors the game** (`Database.get_*_sound_path` in the
  frontend): `<Grapheme>-<Phoneme>.mp3` for a GP, `<text>.mp3` for a syllable or
  word, after replacing `/ \ : * ? " < > |` with `_`. Sentences have no
  recording; they play their words in order.
- **Do not extract the pack.** Only `language.db` is written out. Audio is read
  from the open `ZIPReader` on demand. A pack holds 20–55 MB of MP3 files and in
  a browser the user filesystem sits in memory.
- **Do not turn on `Thread Support`** in the export preset. Off is what keeps
  the build out of cross-origin isolated mode and hostable on a plain server.
  `Extensions Support` must stay **on** or there is no SQLite.
- **`PackedStringArray(...)` and `PackedByteArray(...)` are not constant
  expressions** in GDScript. Use `const x: Array[String] = [...]` and convert at
  the point of use.
- **The interface is built in code**, not in scenes. `main.tscn` holds a single
  node. `CheckList.setup()` is normally called before the node is in the tree, so
  `_ready()` finishes the job — watch that ordering when editing it.
- Lists use a `Tree`, not instantiated rows: a pack has up to 2500 words and a
  `Tree` only draws what is visible.

## Verifying changes

There is no editor in CI, so all three checks are scripted. Run at least the
first after any change to pack reading or reporting:

```bash
# pipeline against real packs
godot --headless --path . --script tests/pack_smoke_test.gd -- ~/packs/fr_FR.zip ~/packs/es_UY.zip

# pictures of every screen
godot --path . --resolution 1280x800 --script tests/ui_capture.gd -- ~/packs/fr_FR.zip ~/shots

# the exported build, in a real browser (see README for the full invocation)
node tests/web_e2e.mjs http://localhost:8099/index.html http://localhost:8099/testpack.zip /tmp/dl /tmp/shots
```

The web run is the only place that proves SQLite opens a database on the
browser's filesystem; look for `Opened database successfully` in its console
output.

## Conventions

- **Written language: English**, everywhere — code, comments, commit messages,
  PRs, docs, and the tool's own interface — even when the conversation is in
  French.
- The interface is English only. Testers of the Spanish and Portuguese packs read
  English wording; if that turns out to be a problem, add Godot translations
  rather than hard-coding a second language.
- File names: lowercase with underscores.
- No secrets in this repository; there is nothing to authenticate against.
