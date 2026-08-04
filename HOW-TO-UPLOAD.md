# How to publish the Language Pack Checker

This is the whole procedure for putting the checker online, from a fresh clone
to a URL you can send to testers.

The build is a **plain static site**: no PHP, no Node, no database, and — worth
saying because Godot's documentation often implies otherwise — **no special HTTP
headers**. Any web server that can serve files will do.

It currently runs at **https://kalulu.excellolab.org/lang-tester/**, on the
`excello-multisite-main` Lightsail instance. Section 4 is the exact procedure
that was used; follow it if you are redeploying to the same place. Section 7 is
for hosting it somewhere else.

---

## 1. Build

You need **Godot 4.7.1** and its **Web export templates** of the same version
(`Editor > Manage Export Templates…`, or download
`Godot_v4.7.1-stable_export_templates.tpz` from the Godot releases page — they
are not bundled with the editor).

```bash
godot --headless --path . --export-release "Web" build/lang-tester/index.html
```

Exporting into a folder called `lang-tester` means the zip you make from it
unpacks straight into the right directory name on the server.

The `Web` preset is committed in `export_presets.cfg`. Two of its options matter
and must not be changed without reading section 6:

| Option | Value | Why |
|---|---|---|
| `Extensions Support` | **on** | The checker reads `language.db` with the `godot-sqlite` GDExtension. Without this there is no SQLite and no pack will ever open. |
| `Thread Support` | **off** | Keeps the build out of "cross-origin isolated" mode, which is what lets it be hosted on an ordinary server. See section 6. |

---

## 2. What to upload

The **contents** of `build/lang-tester/` — 11 files:

```
index.html                                        the page
index.js                                          engine loader
index.wasm                                        engine
index.side.wasm                                   engine (GDExtension build, the big one)
libgdsqlite.web.template_release.wasm32.nothreads.wasm   SQLite
index.pck                                         the checker itself
index.audio.worklet.js
index.audio.position.worklet.js
index.png  index.icon.png  index.apple-touch-icon.png
```

**Nothing else.** If you have been testing locally, `build/lang-tester/` may also
contain a `.zip` test pack or `*.import` files. Do not publish those. Check with
`ls` before zipping.

```bash
cd build && zip -r -9 lang-tester.zip lang-tester
```

That gives you roughly a 12 MB archive containing a single `lang-tester/` folder.

All paths inside `index.html` are relative, so the site works at the root of a
domain or in a subfolder, with nothing to configure either way.

---

## 3. The two server settings that actually matter

### 3.1 Compression — do not skip this

The build is about **49 MB uncompressed** and about **11 MB gzipped** (9 MB with
brotli). Almost all of it is one file, `index.side.wasm`. Without compression
every tester downloads 49 MB before seeing anything.

It is tempting to treat that as acceptable — it is not. This is a one-off tool,
not a game somebody replays, so first-load time *is* the whole experience. Our
testers for `es_AR`, `es_CO`, `es_UY` and `pt_BR` are in Argentina, Colombia,
Uruguay and Brazil, and 49 MB of blank screen is exactly where a volunteer gives
up. It is also one line of configuration, so there is no reason to defer it.

Make sure `.wasm`, `.js` and `.pck` are compressed. Most servers do **not**
compress `.wasm` by default, because it is not in their standard type list.

### 3.2 MIME type for `.wasm`

`.wasm` must be served as `application/wasm`. If it arrives as
`application/octet-stream` the browser refuses to stream-compile it: a slow load
at best, a blank page at worst.

Everything else can be served as `application/octet-stream` — the engine does not
care, and that is already Apache's default for unknown extensions, so `.pck`
needs no configuration.

---

## 4. Deploying to our server (Lightsail + Bitnami WordPress)

The instance is `excello-multisite-main` in `eu-west-3` (Paris), static IP
`15.236.191.115`, running the legacy Bitnami WordPress **Multisite** image.

Three things about it are not obvious and cost time if you do not know them:

- **`.htaccess` files are ignored.** The instance runs `AllowOverride None`, so
  any `.htaccess` you write does nothing *and reports no error*. All
  configuration goes in `/opt/bitnami/apache/conf/vhosts/`, which Bitnami
  includes by design.
- **The path is `/opt/bitnami/apache`, not `apache2`.** There is an
  `apache2_backup` directory left over from an upgrade; ignore it.
- **Multisite means one shared document root.** There is no per-subdomain
  folder. `/lang-tester` therefore answers on every domain in the network, not
  just `kalulu.`. Harmless for an unlisted tool, but do not go looking for a
  `kalulu`-specific directory — there isn't one.

There is also **no WordPress page and no iframe**. The URL is unlisted and sent
directly to testers, so an iframe would add nothing while making the file picker
and the CSV download more fragile — iframes are where browsers get aggressive
about blocking both. Just link the URL.

### 4.1 Confirm the layout is still what we expect

The Bitnami image is no longer maintained, so re-derive the paths rather than
trusting this document if anything looks off:

```bash
echo "=== layout ==="; ls -d /opt/bitnami/wordpress /opt/bitnami/apps/wordpress/htdocs 2>/dev/null
echo "=== document root ==="; grep -rh "DocumentRoot" /opt/bitnami/apache*/conf/vhosts/*.conf 2>/dev/null | sort -u
echo "=== AllowOverride ==="; grep -rh "AllowOverride" /opt/bitnami/apache*/conf/vhosts/*.conf /opt/bitnami/apache*/conf/httpd.conf 2>/dev/null | sort | uniq -c
echo "=== modules ==="; sudo /opt/bitnami/apache/bin/apachectl -M 2>/dev/null | grep -E "deflate|headers|rewrite"
```

Expected: document root `/opt/bitnami/wordpress`, `AllowOverride None`
throughout, and `deflate_module`, `headers_module`, `rewrite_module` all present.

### 4.2 Get the archive onto the instance

Lightsail's browser SSH client cannot transfer files, so use the instance key:
Lightsail → account menu → **Account** → **SSH keys** → download the default key
for `eu-west-3`.

```bash
chmod 400 ~/Downloads/LightsailDefaultKey-eu-west-3.pem
scp -i ~/Downloads/LightsailDefaultKey-eu-west-3.pem build/lang-tester.zip bitnami@15.236.191.115:~/
ssh -i ~/Downloads/LightsailDefaultKey-eu-west-3.pem bitnami@15.236.191.115
```

The user on these images is `bitnami`.

### 4.3 Put the files in place

```bash
sudo unzip -o ~/lang-tester.zip -d /opt/bitnami/wordpress/
sudo chown -R bitnami:daemon /opt/bitnami/wordpress/lang-tester
sudo find /opt/bitnami/wordpress/lang-tester -type d -exec chmod 775 {} \;
sudo find /opt/bitnami/wordpress/lang-tester -type f -exec chmod 664 {} \;
```

`bitnami:daemon` with 775/664 is the pattern the rest of WordPress uses, so
Apache — which runs as `daemon` — can read the files.

### 4.4 Install the Apache configuration

The file to install is [deploy/lang-tester.conf](deploy/lang-tester.conf) in this
repository. Copy it to the server as
`/opt/bitnami/apache/conf/vhosts/lang-tester.conf`, then:

```bash
sudo /opt/bitnami/apache/bin/apachectl configtest && sudo /opt/bitnami/ctlscript.sh restart apache
```

**Always run `configtest` first.** This is a live site: if the syntax is wrong,
`configtest` fails, the `&&` stops there, and Apache is never restarted.

To back the whole thing out: delete
`/opt/bitnami/apache/conf/vhosts/lang-tester.conf`, restart Apache, and remove
`/opt/bitnami/wordpress/lang-tester`.

### 4.5 Updating an existing deployment

Rebuild, rezip, scp, then repeat 4.3 only. The configuration does not change, so
Apache does not need restarting. `index.html` is served with `no-cache`, so
testers pick up the new build on their next visit.

---

## 5. Check it worked

From anywhere:

```bash
curl -s -o /dev/null -w "page:  %{http_code}  %{content_type}\n" https://kalulu.excellolab.org/lang-tester/
curl -s -o /dev/null -w "wasm:  %{http_code}  %{content_type}  encoding=%{content_encoding}  transferred=%{size_download} bytes\n" -H "Accept-Encoding: gzip" https://kalulu.excellolab.org/lang-tester/index.side.wasm
```

| Field | Expected | If it is wrong |
|---|---|---|
| `page` code | `200` | 404: files not in place, or `DirectoryIndex` does not list `index.html` — try `/lang-tester/index.html` |
| `wasm` content_type | `application/wasm` | `octet-stream`: the `AddType` line is not applying. Blank page in the browser. Section 3.2 |
| `wasm` transferred | **~10–11 MB** | ~44 MB: compression is off. Section 3.1 |

The transferred byte count is the honest test of compression: a response header
can be misleading, 10 MB instead of 44 MB cannot.

Then open the page and confirm, in order:

1. The title **"Kalulu — Language Pack Checker"** appears.
2. Step 1 lists five language packs with sizes (40–90 MB). Names but no sizes
   means the GitHub API call did not go through and the page fell back to a
   static list — harmless.
3. The browser console (F12) says
   `Build configuration: … single-threaded, GDExtension support.`
   If `GDExtension support` is missing, the build was made without
   `Extensions Support` and no pack will ever open — rebuild, section 1.
4. Download a pack and open it with **Choose a .zip file…**. A progress bar
   appears, then the four tabs fill with entries.
5. Press a ▶ button and listen. Sound confirms the whole chain works.
6. Reload and **drag** the same .zip onto the page. This second route cannot be
   tested automatically — the engine resolves drops with `webkitGetAsEntry()`,
   which only answers for a real drag from the desktop — so confirm it by hand
   once per deployment. If it fails, the button still works, and the page leads
   with the button.

---

## 6. Why there are no COOP/COEP headers

Godot web builds are widely documented as needing:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Those are only required when the build uses threads, and this one does not
(`Thread Support` is off). That is deliberate: it is what lets the checker run
from a subfolder of an existing WordPress site with no server changes beyond one
MIME type.

The checker does not need threads — it never extracts the pack's audio, it reads
each recording out of the ZIP when the tester presses play.

If anyone ever turns `Thread Support` on, those two headers become mandatory and
the hosting requirements get considerably stricter. Do not turn it on without a
reason.

HTTPS is not strictly required, but use it: the page fetches the pack list from
`https://api.github.com`, and browsers are increasingly unhappy about mixed
contexts. Nothing a tester does is ever uploaded — the pack is read in the
browser and the report is downloaded as a file — so there is no server-side
privacy consideration and no data to protect.

---

## 7. Hosting it somewhere else

Only section 3 really matters. Concretely:

**Apache**, where `.htaccess` *is* enabled — the same directives as
[deploy/lang-tester.conf](deploy/lang-tester.conf) work in a `.htaccess` next to
`index.html`, minus the `<Directory>` wrapper.

**nginx:**

```nginx
location /lang-tester/ {
    types { application/wasm wasm; }   # or add it to mime.types globally
    gzip on;
    gzip_types application/wasm application/javascript text/html;
    gzip_min_length 1024;
}
```

Better still, pre-compress once and serve with `gzip_static on;`:

```bash
cd build/lang-tester && gzip -9 -k index.side.wasm index.wasm index.js index.pck
```

**S3 + CloudFront:** S3 will not compress for you, so pre-compress and upload
each file with `--content-encoding gzip` and the correct `--content-type`
(`application/wasm` for the two `.wasm` files). Upload `index.html` with
`--cache-control no-cache`, everything else with a long `max-age`. Then
invalidate the CloudFront path.

---

## 8. If something is wrong

| What you see | Cause |
|---|---|
| Blank page; console mentions `application/wasm` or `Incorrect response MIME type` | Wrong MIME type for `.wasm`. Section 3.2 |
| Loads, but very slowly the first time | Compression is off. Section 3.1 |
| Configuration edits appear to do nothing at all | You edited a `.htaccess` on a server with `AllowOverride None`. Section 4 |
| Every pack fails with "Could not read the language database" | Built without `Extensions Support`. Section 1 |
| Console mentions `SharedArrayBuffer` or cross-origin isolation | Built with `Thread Support` on. Section 6 |
| WordPress 404 page instead of the tool | WordPress's rewrite rules claimed the path. The `RewriteEngine Off` block in `deploy/lang-tester.conf` is what prevents this |
| "Choose a .zip file…" does nothing | The browser blocked the file dialog. Testers can drag the .zip onto the page instead |
| Testers see an old version after you upload | `index.html` was cached. Section 4.4 sets `no-cache` on it |

---

## 9. What to tell your testers

Something along these lines:

> Please help us check the Kalulu reading content:
> **https://kalulu.excellolab.org/lang-tester/**
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
