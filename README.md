# Kalulu Language Pack Checker

A small web tool that lets volunteer testers review the contents of a Kalulu
language pack — the grapheme-phoneme pairs, syllables, words and sentences,
together with the recordings the game plays for them — and report anything that
is wrong.

No account, no server, nothing uploaded. The tester picks a language, the pack
downloads itself, and they work through the four lists and leave with a CSV
report to email to `contact@excellolab.org`.

Part of the [Kalulu](https://github.com/Excello-Recherche-Education/Kalulu)
project by [Excello Recherche & Éducation](https://github.com/Excello-Recherche-Education).

---

## What a tester does

1. **Pick a language.** The first screen lists every pack with its size and the
   date it was published, and one button per row. Pressing it downloads the pack
   and opens it — the tester never sees a `.zip`, and never has to know where the
   packs are kept. The list is read from the storage itself when the page loads,
   so adding a locale is a pure upload: nothing here needs rebuilding and no code
   changes.
2. **Come back whenever.** The pack is kept in the browser's own storage, so
   closing the tab and returning tomorrow opens it again instantly instead of
   downloading 90 MB a second time. That row then reads *on this computer*.
3. **Get updates in one press.** Each pack's published date is remembered
   alongside it. When a newer one has been put up, the row says *new version
   available* and the button becomes **Update**. Nothing downloads on its own —
   an update is always the tester's decision.
4. **Check it.** Four tabs — **GP**, **Syllables**, **Words**, **Sentences** —
   each listing every entry with its lesson number, a ▶ button for its
   recording, a box to tick when something is wrong, and a field to say what.
   Entries whose recording is absent from the pack are marked `missing` in red.
5. **Send the report.** *Finish and download my report* produces a CSV and a
   thank-you screen with a `mailto:` link.

Opening a `.zip` by hand still works, from the bottom of the first screen or by
dragging it onto the page. It is the way in when the storage cannot be reached,
and the only way to look at a pack that has not been published yet.

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

- **Packs come from S3, not from the GitHub releases.** Not a preference: GitHub
  sends no `Access-Control-Allow-Origin` on release assets, so a browser throws
  away a response it has already received, and no amount of code here can change
  that. They are served instead from the `Languages-Checker/` folder of the
  bucket the game already downloads from, which is public for exactly this
  purpose. The game reaches the same packs through a presigned URL because it is
  a native build, where CORS does not apply.
- **The pack is kept between visits, one at a time.** It is written to the
  browser's storage (IndexedDB) with its published date beside it, which is what
  makes "come back tomorrow" and "a new version is available" possible. Only one
  is kept: in a browser the whole user filesystem is held in memory, so five
  packs would mean carrying ~295 MB of it. Reports are unaffected — they are
  saved per locale and outlive the archive they were written against.
- **The download is done in JavaScript, on the web.** `HTTPRequest`'s
  `set_download_file()` reports a complete, successful transfer in the web export
  and writes no file at all, so the browser fetches the pack itself and hands it
  over a slice at a time — the same shape as reading a file the tester picked.
  Desktop uses `HTTPRequest` normally. Either way the size on disk is what
  decides success, never the result code.
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
│   ├── pack_downloader.gd     fetches a pack into the browser's storage
│   ├── pack_cache.gd          what is kept between visits, and its version
│   └── available_packs.gd     the downloadable list, read from S3
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

**The download path**, against the real storage — lists the packs, downloads the
smallest, checks the version was recorded, and opens what arrived:

```bash
godot --headless --path . --script tests/download_test.gd
godot --headless --path . --script tests/download_test.gd -- fr_FR
```

It really does transfer the pack, so it takes about as long as the download
does. Passing here does *not* mean the web build can download: it runs on
desktop, where `HTTPRequest` works and CORS does not exist.

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

**Downloading, in a real browser** — the only run that proves the two things
which cannot be checked anywhere else: that the storage really does send the
CORS headers a browser demands, and that the pack survives a reload in
IndexedDB. It clicks Download, waits for SQLite to open the database, reloads
the page, opens the pack again, and asserts the pack was fetched **exactly
once** across the whole run:

```bash
node tests/web_download_e2e.mjs http://localhost:8099/index.html /tmp/kalulu_shots
```

Same Chrome invocation as above. It drives a canvas at measured coordinates, so
if a click lands on the wrong row, re-measure from the `01_pack_list.png` it
saves — the constants are at the top of the file, and the web positions are not
the same as the desktop ones.

---

## Related repositories

| Repository | Role |
|---|---|
| [Kalulu](https://github.com/Excello-Recherche-Education/Kalulu) | The game and the Prof Tool that authors packs |
| [Kalulu-Languages](https://github.com/Excello-Recherche-Education/Kalulu-Languages) | The packs themselves, published as releases |
| Kalulu-AWS-Lambda | The backend the game talks to — the checker does not use it |

The checker downloads packs straight from the public `Languages-Checker/` folder
of the `kalulu-app-language-packs` bucket, so it needs no backend and no
credentials of its own. **Publishing a Kalulu-Languages release does not put a
pack in front of testers** — it has to be copied into that folder, which is a
server-side copy and moves no bytes:

```bash
aws s3 cp s3://kalulu-app-language-packs/fr_FR.zip \
          s3://kalulu-app-language-packs/Languages-Checker/fr_FR.zip --profile kalulu
```

Keeping that folder separate from the packs the game downloads is deliberate: a
pack can be put in front of testers before it goes anywhere near production. Only
that folder is readable without credentials — the root packs and the database
dumps beside them answer 403.

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
