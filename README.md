# Kalulu Language Pack Checker

A small web tool that lets volunteer testers review the contents of a Kalulu
language pack — the grapheme-phoneme pairs, syllables, words and sentences,
together with the recordings the game plays for them — and report anything that
is wrong.

No account, no server, nothing uploaded. The tester downloads a pack, opens it
in the page, works through the four lists, and leaves with a CSV report to email
to `contact@excellolab.org`.

Part of the [Kalulu](https://github.com/Excello-Recherche-Education/Kalulu)
project by [Excello Recherche & Éducation](https://github.com/Excello-Recherche-Education).

---

## What a tester does

1. **Get a pack.** The first screen lists the packs in the **latest**
   [Kalulu-Languages release](https://github.com/Excello-Recherche-Education/Kalulu-Languages/releases)
   with their real sizes, and a download button for each. The list is read from
   GitHub when the page loads, so publishing a release is all it takes to put
   new packs in front of testers — nothing here needs rebuilding, and adding a
   locale needs no code change. Note that GitHub's "latest" skips prereleases,
   so pack releases must not be marked as such.
2. **Open it.** Use the file button, or drag the `.zip` onto the page. The pack
   is read locally; it never leaves the machine.
3. **Check it.** Four tabs — **GP**, **Syllables**, **Words**, **Sentences** —
   each listing every entry with its lesson number, a ▶ button for its
   recording, a box to tick when something is wrong, and a field to say what.
   Entries whose recording is absent from the pack are marked `missing` in red.
4. **Send the report.** *Finish and download my report* produces a CSV and a
   thank-you screen with a `mailto:` link.

The report is saved in the browser as it is written, so closing the tab does not
lose an afternoon's work.

### The CSV

```csv
Locale,Category,Text,User report
fr_FR,GP,r-R,the recording says something else
fr_FR,Word,mono,spelling is wrong, should be "mono."
```

`Locale` is there because five packs are in circulation and a report that does
not say which one it concerns cannot be acted on. The file carries a UTF-8 BOM
so accented text survives being opened in Excel on Windows.

---

## Running it

### In the editor

Godot **4.7.1**. Open the project and press play. On desktop the file button is
a normal file dialog, and the report is written next to the user data instead of
being downloaded.

### Building for the web

It is live at **https://kalulu.excellolab.org/lang-tester/**.

```bash
godot --headless --path . --export-release "Web" build/lang-tester/index.html
```

See **[HOW-TO-UPLOAD.md](HOW-TO-UPLOAD.md)** for the rest: what to upload, the
two server settings that matter, the exact procedure for our Lightsail instance,
and how to verify the result. Read it before deploying — the server it runs on
ignores `.htaccess` files, which is not the sort of thing you want to discover
by trial and error.

---

## How it works

A pack is a 40–90 MB ZIP holding a SQLite database, thousands of MP3 files, and
media the checker does not use. Handling that in a browser shapes the design:

- **Only `language.db` is written to disk.** SQLite needs a real file, so that
  one ~600 KB file is extracted. Every recording is read straight out of the
  ZIP when the tester presses play, through `AudioStreamMP3.load_from_buffer()`.
  Nothing else is ever unpacked.
- **`language.db` is the source of truth, not the CSV exports** shipped beside
  it. Some released packs have an empty `words_list.csv` and
  `syllables_list.csv` — `es_CO` is missing all 1622 words and 240 syllables
  from its exports — so reading the CSVs would silently hide most of a pack
  from the tester.
- **Sound file names follow the game.** `<Grapheme>-<Phoneme>.mp3` for a GP,
  `<text>.mp3` for a syllable or word, with the same character substitutions the
  Prof Tool applies. Lookups are matched on the decomposed form of the name,
  because packs built on macOS store `café.mp3` with a combining accent while
  the database spells it precomposed.
- **Matching is case sensitive, deliberately.** Every pack has pairs that differ
  only in case — `e-E` against `e-e`, `r-R` against `r-r` — and they are
  different sounds. A case-insensitive fallback would play the other pair's
  recording, and a tester would hear something plausible and pass an entry whose
  own recording is in fact missing.
- **Sentences have no recording of their own.** The game reads them word by
  word, so the checker plays the word recordings in order and says how many
  there are.
- **No threads.** Not needing them keeps the build out of cross-origin isolated
  mode, which is what makes it hostable anywhere. See HOW-TO-UPLOAD.md §6.
- **The file button is an HTML input in disguise.** Browsers only open a file
  dialog from inside a real click on a real element, and by the time Godot
  reports a button press the browser is no longer in that click. So a
  transparent `<input type="file">` is parked exactly on top of the Godot button
  and follows it. Drag and drop goes through the engine's own handler, which
  resolves the drop with `webkitGetAsEntry()` — that only answers for a drag
  that really came from the desktop, so it cannot be covered by the automated
  test and needs one manual check per deployment.

### Layout

```
sources/
├── main.gd / main.tscn        root; owns the open pack, switches screens
├── pack/
│   ├── pack_archive.gd        read-only view of a <locale>.zip
│   ├── pack_picker.gd         drag-and-drop + browser/desktop file dialog
│   └── available_packs.gd     the downloadable list, from GitHub releases
├── data/
│   ├── checkable.gd           one reviewable entry
│   └── language_data.gd       language.db -> the four lists
├── report/
│   ├── report_store.gd        what the tester flagged, saved as they go
│   └── report_csv.gd          the CSV
├── ui/                        the three screens, the list widget, icons
├── audio/sound_queue.gd       plays recordings out of the ZIP
└── utils/unicode_normalizer.gd  copied from the frontend, keep in sync
```

The interface is built in code rather than in `.tscn` files. There is one scene,
`main.tscn`, holding one node.

---

## Tests

**The pack pipeline**, against real release archives — opens them, reads the
database, resolves every recording, and writes a report:

```bash
godot --headless --path . --script tests/pack_smoke_test.gd -- ~/packs/fr_FR.zip ~/packs/es_UY.zip
```

It also prints how much of each pack has a usable recording, which is a quick
way to see what a pack is missing:

```
GP          118 entries     92 playable     26 missing recording
Syllable    223 entries    223 playable      0 missing recording
Word       2503 entries   2410 playable     93 missing recording
Sentence    252 entries    252 playable     67 missing recording
```

and names anything it hid from the tester, so a fault in a pack is still visible:

```
note  Sentence: 2 repeated (il a gagné un trophée au tennis, …) — hidden from the tester
```

**The interface**, saving a picture of each screen so layout can be reviewed
without opening the editor:

```bash
godot --path . --resolution 1280x800 --script tests/ui_capture.gd -- ~/packs/fr_FR.zip ~/shots
```

**The web build**, end to end in a real browser — feeds a pack to the file
input, waits for SQLite to open it on the browser filesystem, reports a problem,
and checks the CSV that comes out:

```bash
(cd build/lang-tester && python3 -m http.server 8099) &
cp ~/packs/fr_FR.zip build/lang-tester/testpack.zip
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --remote-debugging-port=9222 --window-size=1280,800 \
  --user-data-dir=/tmp/kalulu_chrome --enable-unsafe-swiftshader \
  --use-gl=angle --use-angle=swiftshader about:blank &
node tests/web_e2e.mjs http://localhost:8099/index.html \
  http://localhost:8099/testpack.zip /tmp/kalulu_dl /tmp/kalulu_shots
```

Remember to delete `build/lang-tester/testpack.zip` afterwards so it is never published.

---

## Related repositories

| Repository | Role |
|---|---|
| [Kalulu](https://github.com/Excello-Recherche-Education/Kalulu) | The game and the Prof Tool that authors packs |
| [Kalulu-Languages](https://github.com/Excello-Recherche-Education/Kalulu-Languages) | The packs themselves, published as releases |
| Kalulu-AWS-Lambda | The backend the game talks to — the checker does not use it |

The checker reads packs straight from the GitHub releases, so it needs no
backend and no API access of its own.

---

## License

Copyright (c) 2026 Excello. Licensed under
[Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/)
(CC BY-SA 4.0) — see [LICENSE](LICENSE). Same license as the rest of the Kalulu
project.

One exception: `addons/godot-sqlite/` is not ours. It is
[godot-sqlite](https://github.com/2shady4u/godot-sqlite) by Piet Bronders &
Jeroen De Geeter, vendored here under its own MIT license — see
[addons/godot-sqlite/LICENSE.md](addons/godot-sqlite/LICENSE.md).
