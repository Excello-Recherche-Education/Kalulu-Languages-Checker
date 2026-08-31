class_name PackDownloader
extends Node
## Fetches a pack straight into the browser's storage, so the tester never
## handles a .zip themselves.
##
## ## Two paths, because HTTPRequest cannot do this on the web
##
## `HTTPRequest.set_download_file()` **silently does nothing in the web export**.
## The transfer runs, `request_completed` reports RESULT_SUCCESS and HTTP 200,
## and the file is never created — verified against 4.7.2, where the destination
## folder was still empty after a 41 MB download had visibly completed. Nothing
## in the result says so, which is why the size of what landed on disk is
## checked below rather than trusted.
##
## So on the web the transfer is done in JavaScript instead and the bytes are
## handed over a slice at a time, the same way PackPicker reads a file the
## tester picked. `fetch()` is read through a stream reader and GDScript asks
## for the next slice only once it has written the last one, so a 90 MB pack is
## never held in JavaScript memory in one piece. On desktop HTTPRequest works
## properly and is used as-is.
##
## Whichever path ran, the bytes go to disk as they arrive: a pack is 40-90 MB
## and on the web the user filesystem is held in memory, so assembling the whole
## response first would mean carrying it twice.
##
## ## The stored pack is cleared before the download starts
##
## Not after it succeeds. Keeping the old one until the new one lands would be
## kinder, but it means holding two packs — up to 156 MB of browser memory — and
## this is the one place where running out is most likely. A failed download
## therefore leaves nothing stored, which is recoverable: the tester presses the
## button again. Reports are not touched either way; ReportStore keys them by
## locale.

signal progress(downloaded_bytes: int, total_bytes: int)
signal finished(archive_path: String)
signal failed(message: String)

## Long enough for a 90 MB pack on a slow connection. HTTPRequest counts the
## whole transfer against this, not just the time to first byte.
const REQUEST_TIMEOUT_SECONDS: float = 900.0

## How much the browser accumulates before handing it over. Slices are consumed
## one per frame, so this is a trade between memory and how long a large pack
## takes to write: at 4 MB a 90 MB pack is 23 frames, which is imperceptible.
const CHUNK_SIZE: int = 4 * 1024 * 1024

const _JS_FETCHER: String = """
(function () {
	if (window.__kaluluFetcher) {
		window.__kaluluFetcher.reset();
		return;
	}
	var fetcher = {
		state: 'idle',
		total: 0,
		error: '',
		chunk: null,
		queue: [],
		queued: 0,
		ended: false,
		reader: null,
		target: 4194304,
		start: function (url, target) {
			fetcher.reset();
			fetcher.state = 'fetching';
			fetcher.target = target;
			fetch(url).then(function (response) {
				if (!response.ok) {
					throw new Error('HTTP ' + response.status);
				}
				var length = response.headers.get('Content-Length');
				fetcher.total = length ? parseInt(length, 10) : 0;
				fetcher.reader = response.body.getReader();
				fetcher.pump();
			}).catch(function (error) {
				fetcher.error = String(error && error.message ? error.message : error);
				fetcher.state = 'error';
			});
		},
		pump: function () {
			fetcher.reader.read().then(function (result) {
				if (result.done) {
					fetcher.ended = true;
					fetcher.flush();
					return;
				}
				fetcher.queue.push(result.value);
				fetcher.queued += result.value.length;
				if (fetcher.queued >= fetcher.target) {
					fetcher.flush();
				} else {
					fetcher.pump();
				}
			}).catch(function (error) {
				fetcher.error = String(error && error.message ? error.message : error);
				fetcher.state = 'error';
			});
		},
		flush: function () {
			if (fetcher.queued === 0) {
				fetcher.state = fetcher.ended ? 'done' : 'fetching';
				return;
			}
			var out = new Uint8Array(fetcher.queued);
			var at = 0;
			for (var i = 0; i < fetcher.queue.length; i++) {
				out.set(fetcher.queue[i], at);
				at += fetcher.queue[i].length;
			}
			fetcher.queue = [];
			fetcher.queued = 0;
			fetcher.chunk = out;
			fetcher.state = 'chunk';
		},
		next: function () {
			fetcher.chunk = null;
			if (fetcher.ended) {
				fetcher.state = 'done';
				return;
			}
			fetcher.state = 'fetching';
			fetcher.pump();
		},
		reset: function () {
			if (fetcher.reader) {
				try { fetcher.reader.cancel(); } catch (error) { /* already done */ }
			}
			fetcher.state = 'idle';
			fetcher.total = 0;
			fetcher.error = '';
			fetcher.chunk = null;
			fetcher.queue = [];
			fetcher.queued = 0;
			fetcher.ended = false;
			fetcher.reader = null;
		}
	};
	window.__kaluluFetcher = fetcher;
})();
"""

var _is_web: bool = OS.has_feature("web")
var _request: HTTPRequest = null
var _fetcher: JavaScriptObject = null

var _pack: Dictionary = {}
var _destination_path: String = ""
var _expected_bytes: int = 0

# Web path only: the file being appended to, and how much has reached it.
var _destination: FileAccess = null
var _written_bytes: int = 0


func _ready() -> void:
	if _is_web:
		JavaScriptBridge.eval(_JS_FETCHER, true)
		_fetcher = JavaScriptBridge.get_interface("window").__kaluluFetcher
		if _fetcher == null:
			push_warning("PackDownloader: the browser cannot fetch, downloads are unavailable")
	else:
		_request = HTTPRequest.new()
		_request.use_threads = false
		_request.timeout = REQUEST_TIMEOUT_SECONDS
		_request.request_completed.connect(_on_request_completed)
		add_child(_request)
	set_process(false)


## True when this browser cannot download at all, so the tester can be pointed
## at the manual route instead of at a button that will never work.
func is_available() -> bool:
	return not _is_web or _fetcher != null


func is_busy() -> bool:
	return not _pack.is_empty()


## Starts fetching `pack`, as handed out by AvailablePacks. Exactly one of
## `finished` or `failed` will fire.
func download(pack: Dictionary) -> void:
	if is_busy():
		return
	if not is_available():
		_fail("This browser cannot download the pack. Download it yourself and open it below.")
		return

	var url: String = str(pack.get("url", ""))
	var file_name: String = str(pack.get("file_name", ""))
	if url.is_empty() or file_name.is_empty():
		_fail("There is no address for this pack. Please tell us which language you picked.")
		return

	var directory_error: Error = PackCache.ensure_directory()
	if directory_error != OK:
		_fail("Could not make room for the pack in this browser (%s)."
				% error_string(directory_error))
		return

	# The one-at-a-time rule. Also clears a half-written archive from a download
	# that was interrupted, which would otherwise sit there taking up room.
	PackCache.clear()

	_pack = pack
	_expected_bytes = int(pack.get("size", 0))
	_destination_path = PackCache.path_for(file_name)
	_written_bytes = 0

	if _is_web:
		_destination = FileAccess.open(_destination_path, FileAccess.WRITE)
		if _destination == null:
			var open_error: Error = FileAccess.get_open_error()
			_reset()
			_fail("Could not store the pack in this browser (%s)." % error_string(open_error))
			return
		_fetcher.start(url, CHUNK_SIZE)
	else:
		_request.download_file = _destination_path
		var error: Error = _request.request(url)
		if error != OK:
			_reset()
			_fail("Could not start the download (%s). Check your connection and try again."
					% error_string(error))
			return

	progress.emit(0, _expected_bytes)
	set_process(true)


func cancel() -> void:
	if not is_busy():
		return
	if _is_web:
		_fetcher.reset()
	else:
		_request.cancel_request()
	_reset()
	PackCache.clear()


func _process(_delta: float) -> void:
	if _is_web:
		_poll_browser()
		return

	var downloaded: int = _request.get_downloaded_bytes()
	# get_body_size() is -1 until the response headers arrive, and stays -1 when
	# the server does not send a length. The listing already told us the size, so
	# prefer that and the bar never sits at an unknown maximum.
	var total: int = _expected_bytes
	if total <= 0:
		total = _request.get_body_size()
	progress.emit(maxi(downloaded, 0), total)


func _poll_browser() -> void:
	match str(_fetcher.state):
		"chunk":
			_consume_chunk()
		"done":
			_complete()
		"error":
			var message: String = str(_fetcher.error)
			_fetcher.reset()
			_abort()
			_fail(_browser_message(message))


func _consume_chunk() -> void:
	var chunk: Variant = _fetcher.chunk
	if not JavaScriptBridge.is_js_buffer(chunk):
		_fetcher.reset()
		_abort()
		_fail("The browser returned an unreadable part of the download.")
		return

	var bytes: PackedByteArray = JavaScriptBridge.js_buffer_to_packed_byte_array(chunk)
	_destination.store_buffer(bytes)
	# A pack is up to 90 MB and the browser gives this storage grudgingly, so a
	# write can fail part way through. Saying so beats handing back a truncated
	# archive that fails later as "this is not a .zip".
	var write_error: Error = _destination.get_error()
	if write_error != OK and write_error != ERR_FILE_EOF:
		_fetcher.reset()
		_abort()
		_fail("This browser ran out of room while storing the pack (%s). "
				% error_string(write_error)
				+ "Free some space for this site, or try a different browser.")
		return

	_written_bytes += bytes.size()
	var total: int = _expected_bytes
	if total <= 0:
		total = int(_fetcher.total)
	progress.emit(_written_bytes, total)
	_fetcher.next()


func _complete() -> void:
	_destination.close()
	_destination = null
	_fetcher.reset()

	var destination: String = _destination_path
	var pack: Dictionary = _pack
	var written: int = _written_bytes
	_reset()
	_settle(destination, pack, written)


func _on_request_completed(
		result: int,
		response_code: int,
		_headers: PackedStringArray,
		_body: PackedByteArray) -> void:
	var destination: String = _destination_path
	var pack: Dictionary = _pack
	_reset()

	if result != HTTPRequest.RESULT_SUCCESS:
		PackCache.clear()
		_fail(_transfer_message(result))
		return

	if response_code != 200:
		PackCache.clear()
		_fail(_status_message(response_code))
		return

	_settle(destination, pack, _size_on_disk(destination))


## Shared final step: what is actually on disk decides, not what the transfer
## claimed. A truncated archive would otherwise surface much later as "this is
## not a .zip", with the real cause long out of sight — and on the web a
## transfer can report complete success having written nothing at all.
func _settle(destination: String, pack: Dictionary, written: int) -> void:
	var on_disk: int = _size_on_disk(destination)
	var expected: int = int(pack.get("size", 0))

	if on_disk <= 0:
		PackCache.clear()
		_fail("Nothing was saved. This browser may be out of room for this site.")
		return
	if expected > 0 and on_disk != expected:
		PackCache.clear()
		_fail("Only part of the pack arrived (%d of %d MB). Please try again."
				% [on_disk / (1024 * 1024), expected / (1024 * 1024)])
		return
	if written > 0 and written != on_disk:
		PackCache.clear()
		_fail("The pack was not stored correctly. Please try again.")
		return

	PackCache.record(
			str(pack.get("locale", "")),
			str(pack.get("file_name", "")),
			str(pack.get("version", "")),
			on_disk)
	# PackCache.record() syncs, so the archive and its record reach IndexedDB
	# together and the pack survives a reload.
	finished.emit(destination)


## `fetch()` reports a cross-origin refusal and an unplugged cable identically,
## as a bare "Failed to fetch", so the wording has to cover both.
func _browser_message(error: String) -> String:
	if error.begins_with("HTTP "):
		return _status_message(int(error.trim_prefix("HTTP ")))
	return "The download failed (%s). Check your connection and try again." % error


func _status_message(response_code: int) -> String:
	if response_code == 403 or response_code == 404:
		return ("This pack is not available for download right now (%d). "
				% response_code
				+ "Please tell us which language you picked.")
	return "The download failed (%d). Please try again." % response_code


func _transfer_message(result: int) -> String:
	match result:
		HTTPRequest.RESULT_TIMEOUT:
			return "The download timed out. Packs are large, so a slow connection can take a while — please try again."
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_CONNECTION_ERROR:
			return "Could not reach the pack storage. Check your connection and try again."
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN, HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
			return "This browser ran out of room while saving the pack. Free some space for this site, or try a different browser."
		_:
			return "The download failed (%d). Please try again." % result


func _size_on_disk(path: String) -> int:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size: int = file.get_length()
	file.close()
	return size


## Closes and removes a partly written archive, so a failure never leaves
## something that looks openable behind.
func _abort() -> void:
	if _destination:
		_destination.close()
		_destination = null
	_reset()
	PackCache.clear()


func _reset() -> void:
	set_process(false)
	_pack = {}
	_destination_path = ""
	_expected_bytes = 0
	_written_bytes = 0
	if _destination:
		_destination.close()
		_destination = null
	if _request:
		_request.download_file = ""


func _fail(message: String) -> void:
	failed.emit(message)
