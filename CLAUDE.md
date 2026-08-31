# Kalulu-Languages-Checker — Guide for Claude

## Role

A web tool for volunteer testers to review the contents of a Kalulu language
pack and report data problems: mispronounced or wrong recordings, misspelled
text, missing audio. Output is a CSV, which one press sends to
`developer@excellolab.org` — or which the tester can download and email there
themselves. Nothing is downloaded unless they ask for it.

Read `README.md` first — it explains the tester's journey and the reasoning
behind the design. This file covers only what is easy to get wrong.

## Technology

- **Engine**: Godot 4.7.1 (GDScript)
- **Target**: Web, single-threaded, GDExtension support on
- **SQLite**: `godot-sqlite` 4.7, vendored in `addons/`
- **Almost no backend.** Packs are downloaded straight from S3 by the page
  itself, and there is no account. Exactly one server call exists, it is
  optional, and the tester starts it: `POST /checker_report` sends the finished
  report so they do not have to email it by hand. See `report_sender.gd` here
  and `handlers/checker_report.py` in Kalulu-Backend.

  **Nothing about the pack is ever uploaded**, and that claim is made on screen
  — keep it true. What leaves the machine is the report the tester wrote, and
  only when they press the button. Their name and address are optional.

## Publishing a pack for testers

Packs are served from the **`Languages-Checker/` folder** of the
`kalulu-app-language-packs` bucket (`eu-west-3`) — *not* from the bucket root,
which is what the game downloads through a presigned URL, and *not* from GitHub
releases. Publishing a release does **not** put it in front of testers. Copy it
across, server-side, so no bytes travel:

```bash
aws s3 cp s3://kalulu-app-language-packs/fr_FR.zip \
          s3://kalulu-app-language-packs/Languages-Checker/fr_FR.zip --profile kalulu
```

The checker lists that folder, so a new locale needs no code change and no
rebuild — the upload is the whole deployment. The last-modified date of each
object is the version testers are shown and what an update is judged against, so
re-uploading an unchanged pack asks every tester to download it again.

Only that folder is public: anonymous `GetObject` on `Languages-Checker/*` and
anonymous `ListBucket` scoped to the same prefix. The root packs and
`language-db-dumps/` answer 403, and must keep doing so.

## Things that will bite you

- **A browser cannot download a GitHub release asset, ever.** GitHub sends no
  `Access-Control-Allow-Origin` on release assets — not on the `github.com`
  redirect, not on the `release-assets.githubusercontent.com` blob behind it —
  so the browser discards a response it has already received. The API endpoint
  does send the header but redirects to that same blob host, and CORS is judged
  on the final response. This is why packs are served from S3 instead. The game
  gets away with GitHub-shaped URLs because it is a **native** build, where CORS
  does not exist; do not reason from what the frontend does.
- **`HTTPRequest.set_download_file()` silently does nothing in the web export.**
  Verified on 4.7.2: the transfer runs, `request_completed` reports
  `RESULT_SUCCESS` and HTTP 200, and no file is ever created — the destination
  folder was still empty after a 41 MB download had visibly finished. So
  `PackDownloader` fetches through JavaScript on the web and uses `HTTPRequest`
  only on desktop. Never trust the result code: what is on disk decides, which
  is what `PackDownloader._settle()` is for.
- **GDScript lambdas capture by value.** `var done := false` assigned from
  inside a signal callback stays `false` outside it, so a wait loop spins until
  it times out on a request that in fact succeeded. This cost an afternoon in
  `tests/download_test.gd`; collect signal results into **members**, never into
  locals a lambda closes over.
- **One pack is kept at a time, on purpose.** In a browser the whole user
  filesystem is held in memory, so five packs would mean carrying ~295 MB of it.
  Downloading a different locale replaces the stored one. Reports are unaffected:
  `ReportStore` keys them by locale and they outlive the archive.
- **The posted report loses its byte order mark; the endpoint puts it back.**
  `ReportCsv.build()` writes a UTF-8 BOM because Excel on Windows otherwise
  reads the file as Latin-1 and mangles every accented word — which on these
  packs is most of them. But `PackedByteArray.get_string_from_utf8()` **strips a
  leading BOM**, so what `ReportSender` posts has none even though the
  downloaded copy does. `handlers/checker_report.py` normalises the attachment
  to carry exactly one. Do not "fix" this by prepending one in the checker: the
  two ship separately and you would get two. There is a contract test for it,
  built from a payload this checker really produced —
  `tests/report_payload_dump.gd` regenerates the fixture.
- **The API's stage name goes in the path, not just the host.** The custom
  domains map with an empty key onto routes declared `ANY /prod/{proxy+}` and
  `ANY /dev/{proxy+}`, so the working addresses are
  `https://api.kalulu.org/**prod**/<route>` and
  `https://dev.api.kalulu.org/**dev**/<route>`. Drop the segment and API Gateway
  answers its own `{"message":"Not Found"}` without ever reaching the Lambda —
  which reads exactly like a route that was never deployed, and sent me looking
  in the wrong place. When it *does* reach the Lambda you get the Lambda's own
  wording instead: `{"error": "Path /… not found in routes"}`. That difference
  is the quickest way to tell a bad URL from a missing route.
- **Reports go to the *dev* stage, on purpose.** The checker is an internal tool
  for a handful of volunteers, not part of the product, so it has no business
  depending on a production deploy or adding traffic to the stack the game
  relies on. The practical effect: merging and deploying **DEV** is all it takes
  to make the button work — promoting to PROD is not required. The cost is that
  `dev` tracks `$LATEST`, so a deploy mid-review can cost one send; the download
  is still sitting there when it does.

  `?api=prod` switches to production, should the tool ever need to outlive dev.
  Only the exact word `prod` does anything and both addresses are constants in
  `ReportSender` — a query parameter that could name a host would turn a crafted
  link into a way of collecting other people's reports. On desktop the same
  choice is `-- --api prod`.
- **Sending must never replace the download.** If the endpoint is unreachable —
  offline, not deployed yet, backend down — the tester still has the CSV and the
  address. A failure is the moment they are most likely to close the tab
  believing the work is gone, so the failure message points back at the
  buttons that still work.
- **Writing a pack and persisting it are not the same moment.**
  `JavaScriptBridge.force_fs_sync()` is asynchronous and there is no way to await
  it from GDScript — the completion flag lives on `GodotFS._syncing`, inside the
  module closure, and neither `FS` nor `Module` is reachable from page scope.
  Measured against the live site, a 41 MB pack took **between 2 and 10 seconds**
  to reach IndexedDB after the tester was already looking at the entry list. A
  tab closed inside that window loses the pack.

  This is survivable and deliberately so: `PackCache.installed()` checks the
  archive really exists and matches the recorded byte size, so a half-finished
  sync shows up as *Download* again, never as an *Open* button over a truncated
  archive. The cost of the race is one repeated download, and there is no fix
  short of reaching into engine internals — so do not "fix" it by trusting the
  record on its own. **Do not weaken that size check.**

  It also means a test cannot reload straight after a download and expect the
  pack to still be there. `web_download_e2e.mjs` waits for IndexedDB usage to
  settle first; without that wait it passed against a local server and failed
  against the real host, purely on timing.
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

There is no editor in CI, so every check is scripted. Run at least the first
after any change to pack reading or reporting:

```bash
# pipeline against real packs
godot --headless --path . --script tests/pack_smoke_test.gd -- ~/packs/fr_FR.zip ~/packs/es_UY.zip

# the download path against the real bucket: lists, downloads, records, opens
godot --headless --path . --script tests/download_test.gd

# pictures of every screen
godot --path . --resolution 1280x800 --script tests/ui_capture.gd -- ~/packs/fr_FR.zip ~/shots

# the exported build, in a real browser (see README for the full invocation)
node tests/web_e2e.mjs http://localhost:8099/index.html http://localhost:8099/testpack.zip /tmp/dl /tmp/shots
node tests/web_download_e2e.mjs http://localhost:8099/index.html /tmp/shots
```

**The two browser runs are not optional for anything touching downloads.**
`download_test.gd` passes happily against a web build that cannot download at
all — it runs on desktop, where `HTTPRequest` works and CORS does not exist.
Only `web_download_e2e.mjs` sees the two things that actually break: that the
storage sends CORS headers, and that the pack survives a reload in IndexedDB
(it asserts the pack is fetched exactly once across a reload). The web runs are
also the only place that proves SQLite opens a database on the browser's
filesystem; look for `Opened database successfully` in the console output.

`web_download_e2e.mjs` clicks a canvas at measured coordinates, so a layout
change can send the click to the wrong row — the constants at the top of the
file say to re-measure from `01_pack_list.png`, and the desktop and web
positions differ because the intro paragraph wraps at some widths.

## Conventions

- **Written language: English**, everywhere — code, comments, commit messages,
  PRs, docs, and the tool's own interface — even when the conversation is in
  French.
- The interface is English only. Testers of the Spanish and Portuguese packs read
  English wording; if that turns out to be a problem, add Godot translations
  rather than hard-coding a second language.
- File names: lowercase with underscores.
- No secrets in this repository; there is nothing to authenticate against.
