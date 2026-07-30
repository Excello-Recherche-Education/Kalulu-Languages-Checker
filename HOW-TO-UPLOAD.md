# How to publish the Language Pack Checker on a web server

This is the whole procedure for putting the checker online, from a fresh clone
to a URL you can send to testers.

The good news first: the build is a **plain static site**. No PHP, no Node, no
database, no special HTTP headers. Any web server or object store that can serve
files will do.

---

## 1. Build

You need **Godot 4.7.1** and its **Web export templates** of the same version
(`Editor > Manage Export Templates…` in the editor, or download
`Godot_v4.7.1-stable_export_templates.tpz` from the Godot releases page).

```bash
godot --headless --path . --export-release "Web" build/web/index.html
```

The `Web` preset is already committed in `export_presets.cfg`. Two of its
options matter and should not be changed without reading section 5:

| Option | Value | Why |
|---|---|---|
| `Extensions Support` | **on** | The checker reads `language.db` with the `godot-sqlite` GDExtension. Without this the build has no SQLite and no pack will open. |
| `Thread Support` | **off** | Keeps the build out of "cross-origin isolated" mode, which is what lets you host it on an ordinary server. See section 5. |

---

## 2. What to upload

Everything in `build/web/`. Upload the **contents** of that folder, not the
folder itself.

```
index.html                                        the page
index.js                                          engine loader
index.wasm                                        engine
index.side.wasm                                   engine (GDExtension build)
libgdsqlite.web.template_release.wasm32.nothreads.wasm   SQLite
index.pck                                         the checker itself
index.audio.worklet.js
index.audio.position.worklet.js
index.png  index.icon.png  index.apple-touch-icon.png
```

Do not upload anything else that may be sitting in `build/web/` — in
particular no `.zip` test pack and no `*.import` files.

All references inside `index.html` are relative, so the site works both at the
root of a domain and in a subfolder:

- `https://checker.example.org/`
- `https://example.org/kalulu/checker/`

Both are fine. Nothing to configure for either.

---

## 3. Two server settings that actually matter

### 3.1 Compression — do not skip this

The build is about **49 MB uncompressed** and about **11 MB gzipped**
(9 MB with brotli). Nearly all of it is one file, `index.side.wasm`. If your
server does not compress, every tester downloads 49 MB before they see
anything.

Make sure `.wasm`, `.js` and `.pck` are compressed. Most servers do not
compress `.wasm` out of the box, because it is not in their default type list.

### 3.2 MIME type for `.wasm`

`.wasm` must be served as `application/wasm`. If it arrives as
`application/octet-stream`, the browser refuses to stream-compile it; you get a
slow load at best and a blank page at worst.

Everything else (`.pck`, the PNGs) can be served as
`application/octet-stream` — the engine does not care.

---

## 4. Server recipes

### Apache (`.htaccess` next to `index.html`)

```apache
AddType application/wasm .wasm

<IfModule mod_deflate.c>
  AddOutputFilterByType DEFLATE application/wasm application/javascript text/html
</IfModule>

# The engine files are content-addressed by the release you upload, but
# index.html must not be cached or testers will keep running the old build.
<FilesMatch "\.(wasm|pck|js)$">
  Header set Cache-Control "public, max-age=604800"
</FilesMatch>
<FilesMatch "index\.html$">
  Header set Cache-Control "no-cache"
</FilesMatch>
```

### nginx

```nginx
location /kalulu/checker/ {
    types { application/wasm wasm; }   # or add it to mime.types globally

    gzip on;
    gzip_types application/wasm application/javascript text/html;
    gzip_min_length 1024;

    location ~* \.(wasm|pck|js)$ { add_header Cache-Control "public, max-age=604800"; }
    location = /kalulu/checker/index.html { add_header Cache-Control "no-cache"; }
}
```

Better still, pre-compress once and let nginx serve the result with
`gzip_static on;`:

```bash
cd build/web && gzip -9 -k index.side.wasm index.wasm index.js index.pck
```

### Amazon S3 + CloudFront

```bash
cd build/web

# Pre-compress, because S3 will not compress for you.
for f in index.side.wasm index.wasm index.js index.pck; do gzip -9 -c "$f" > "$f.gz"; done

aws s3 cp index.side.wasm.gz s3://BUCKET/checker/index.side.wasm \
  --content-type application/wasm --content-encoding gzip \
  --cache-control "public, max-age=604800"
aws s3 cp index.wasm.gz s3://BUCKET/checker/index.wasm \
  --content-type application/wasm --content-encoding gzip \
  --cache-control "public, max-age=604800"
aws s3 cp index.js.gz s3://BUCKET/checker/index.js \
  --content-type application/javascript --content-encoding gzip \
  --cache-control "public, max-age=604800"
aws s3 cp index.pck.gz s3://BUCKET/checker/index.pck \
  --content-type application/octet-stream --content-encoding gzip \
  --cache-control "public, max-age=604800"

aws s3 cp index.html s3://BUCKET/checker/ --cache-control "no-cache"
aws s3 cp . s3://BUCKET/checker/ --recursive \
  --exclude "*" --include "*.worklet.js" --include "*.png"
```

Then invalidate CloudFront: `aws cloudfront create-invalidation
--distribution-id DIST --paths "/checker/*"`.

---

## 5. Why there are no COOP/COEP headers, and when that changes

Godot web builds have historically needed these two response headers:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

They are only needed when the build uses threads, and this one does not
(`Thread Support` is off). That is deliberate: it means the checker runs on a
shared host, a subfolder of an existing site, or a plain S3 bucket, with no
server configuration at all. It also means the page can still be embedded in
another page if you ever want that.

The checker does not need threads: it never extracts the pack's audio, it reads
each recording out of the ZIP when the tester presses play.

If someone ever turns `Thread Support` back on, the two headers above become
mandatory and the hosting requirements get considerably stricter. Do not turn it
on without a reason.

---

## 6. HTTPS

Serve over HTTPS. It is not strictly required — the checker works over plain
HTTP — but the page fetches the list of available packs from
`https://api.github.com`, and browsers are increasingly unhappy about mixed
contexts. There is nothing to configure beyond having a certificate.

Nothing the tester does is ever uploaded: the pack is read in the browser and
the report is downloaded as a file. So there is no server-side privacy
consideration and no data to protect.

---

## 7. Check it worked

Open the URL and confirm, in order:

1. The page loads and shows **"Kalulu — Language Pack Checker"**.
2. Step 1 lists five language packs with sizes (40–90 MB). If the list shows
   the five names but no sizes, the GitHub API call did not go through — the
   page falls back to a static list, which is harmless.
3. Open the browser console (F12). You should see
   `Build configuration: … single-threaded, GDExtension support.`
   If `GDExtension support` is missing, the build was made without
   `Extensions Support` and no pack will ever open — rebuild.
4. Download a pack and open it with **Choose a .zip file…**. A progress bar
   appears, then the four tabs (GP / Syllables / Words / Sentences) fill with
   entries.
5. Press a ▶ button and listen. Sound is confirmation that the whole chain
   works.
6. Reload the page and **drag** the same .zip onto it. This second route cannot
   be checked automatically — a real drag from the desktop is the only way to
   exercise it — so please confirm it by hand once per deployment. If it does
   not work, the button still does, and the wording on the page leads with the
   button.

In the Network tab, `index.side.wasm` should show a transfer size of about
10 MB, not 42 MB. If it shows 42 MB, compression is not on — go back to 3.1.

---

## 8. If something is wrong

| What you see | Cause |
|---|---|
| Blank page, console mentions `application/wasm` or `Incorrect response MIME type` | `.wasm` MIME type is wrong. Section 3.2. |
| Loads, but very slowly the first time | Compression is off. Section 3.1. |
| `SQLite` errors, or every pack fails with "Could not read the language database" | Built without `Extensions Support`. Section 1. |
| Console mentions `SharedArrayBuffer` or cross-origin isolation | Built with `Thread Support` on. Section 5. |
| Page loads but "Choose a .zip file…" does nothing | The browser blocked the file dialog. Testers can drag the .zip onto the page instead. |
| Testers see an old version after you upload | `index.html` was cached. Section 4. |

---

## 9. What to tell your testers

Something along these lines:

> Please help us check the Kalulu reading content: **<your URL>**
>
> The page explains it in two steps: download the language pack for your
> language, then open that file in the page. You will get four lists — letters
> and sounds, syllables, words, sentences — each with a play button.
>
> When something is wrong (the recording says a different word, the spelling is
> wrong, the sound is silent or cut off), tick the box on that line and write
> what is wrong in your own words. When you are done, press
> **Finish and download my report** and email us the file it gives you.
>
> Nothing is uploaded and no account is needed. You can close the page and come
> back later: your report is kept in your browser.
