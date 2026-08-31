// Drives the exported web build in headless Chrome and checks the two things
// that only exist in a browser, and that nothing else can prove:
//
//   1. A pack can be downloaded at all. The storage must send CORS headers, or
//      the browser discards a response it has already received. This is exactly
//      why packs cannot come from GitHub releases, which send none.
//   2. The pack survives a reload. It is written to IndexedDB, and opening it a
//      second time must cost no network traffic at all — that is the whole
//      point of keeping it.
//
//   node tests/web_download_e2e.mjs <app url> [shot dir]
//
// Chrome must already be listening on 127.0.0.1:9222 with remote debugging.

const [appUrl, shotDir] = process.argv.slice(2);
if (!appUrl) {
	console.error('usage: node tests/web_download_e2e.mjs <app url> [shot dir]');
	process.exit(2);
}

const appOrigin = new URL(appUrl).origin;

// The interface is drawn on a canvas, so there is nothing to query for a
// position. These are measured from 01_pack_list.png at a 1280x800 window, and
// they are not the same as the desktop build's: the intro paragraph wraps onto
// a second line at some widths and shifts every row down by a line. If a click
// lands on the wrong row, re-measure from that screenshot rather than guessing.
const FIRST_ROW_Y = 194;
const ROW_HEIGHT = 36;
const ACTION_BUTTON_X = 1178;

const consoleLines = [];
const requestedUrls = [];
let nextId = 0;
const pending = new Map();
let socket = null;

function send(method, params = {}) {
	const id = ++nextId;
	socket.send(JSON.stringify({ id, method, params }));
	return new Promise((resolve, reject) => {
		pending.set(id, { resolve, reject });
		setTimeout(() => {
			if (pending.delete(id)) reject(new Error(`${method} timed out`));
		}, 60000);
	});
}

async function evaluate(expression, awaitPromise = true) {
	const result = await send('Runtime.evaluate', {
		expression, awaitPromise, returnByValue: true, userGesture: true,
	});
	if (result.exceptionDetails) {
		throw new Error(`page threw: ${JSON.stringify(result.exceptionDetails.exception?.description ?? result.exceptionDetails)}`);
	}
	return result.result.value;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(label, probe, timeoutMs = 120000, intervalMs = 500) {
	const deadline = Date.now() + timeoutMs;
	let last;
	while (Date.now() < deadline) {
		last = await probe();
		if (last) return last;
		await sleep(intervalMs);
	}
	throw new Error(`timed out waiting for ${label} (last value: ${JSON.stringify(last)})`);
}

async function screenshot(name) {
	if (!shotDir) return;
	const { data } = await send('Page.captureScreenshot', { format: 'png' });
	const { writeFile, mkdir } = await import('node:fs/promises');
	await mkdir(shotDir, { recursive: true });
	await writeFile(`${shotDir}/${name}.png`, Buffer.from(data, 'base64'));
	console.log(`  saved ${shotDir}/${name}.png`);
}

async function clickAt(x, y) {
	for (const type of ['mousePressed', 'mouseReleased']) {
		await send('Input.dispatchMouseEvent', {
			type, x, y, button: 'left', clickCount: 1, buttons: type === 'mousePressed' ? 1 : 0,
		});
		await sleep(60);
	}
	await sleep(400);
}

async function waitForEngine() {
	await waitFor('animation frames to run', async () => await evaluate(`
		(async function () {
			var frames = 0;
			function tick() { frames++; requestAnimationFrame(tick); }
			requestAnimationFrame(tick);
			await new Promise(function (r) { setTimeout(r, 400); });
			return frames > 2;
		})();
	`));
	await waitFor('the file picker to be installed', async () =>
		await evaluate('!!window.__kaluluPicker'));
}

const packRequests = () => requestedUrls.filter((u) => /Languages-Checker\/.*\.zip/.test(u));
const listRequests = () => requestedUrls.filter((u) => /list-type=2/.test(u));

// The smallest pack is ~41 MB, so anything above this means a pack really did
// reach IndexedDB rather than just the engine's own cached files.
const MIN_PERSISTED_BYTES = 20 * 1024 * 1024;

async function indexedDbBytes() {
	const report = await send('Storage.getUsageAndQuota', { origin: appOrigin });
	const breakdown = (report.usageBreakdown || []).find((b) => b.storageType === 'indexeddb');
	return Math.round(breakdown?.usage ?? 0);
}

let failures = 0;
function check(what, passed) {
	console.log(`  ${passed ? 'ok  ' : 'FAIL'}  ${what}`);
	if (!passed) failures++;
}

async function main() {
	const targets = await (await fetch('http://127.0.0.1:9222/json')).json();
	const page = targets.find((t) => t.type === 'page');
	if (!page) throw new Error('no page target in Chrome');

	socket = new WebSocket(page.webSocketDebuggerUrl);
	await new Promise((resolve, reject) => {
		socket.addEventListener('open', resolve, { once: true });
		socket.addEventListener('error', reject, { once: true });
	});
	socket.addEventListener('message', (event) => {
		const message = JSON.parse(event.data);
		if (message.id && pending.has(message.id)) {
			const { resolve, reject } = pending.get(message.id);
			pending.delete(message.id);
			message.error ? reject(new Error(JSON.stringify(message.error))) : resolve(message.result);
			return;
		}
		if (message.method === 'Runtime.consoleAPICalled') {
			consoleLines.push(message.params.args.map((a) => a.value ?? a.description ?? '').join(' '));
		}
		if (message.method === 'Log.entryAdded') {
			consoleLines.push(`[${message.params.entry.level}] ${message.params.entry.text}`);
		}
		if (message.method === 'Network.requestWillBeSent') {
			requestedUrls.push(message.params.request.url);
		}
	});

	await send('Runtime.enable');
	await send('Log.enable');
	await send('Page.enable');
	await send('Network.enable');

	// Start as a first visit would: no pack, no reports.
	await send('Storage.clearDataForOrigin', {
		origin: appOrigin, storageTypes: 'indexeddb,local_storage,cache_storage',
	});

	console.log(`Loading ${appUrl}`);
	await send('Page.navigate', { url: appUrl });
	await waitForEngine();
	console.log('  engine is running');

	// The list itself is a cross-origin request. If CORS were wrong this is the
	// first thing that would fail, and every row would fall back to "no size,
	// no date" — so the sizes on screen are the evidence it worked.
	await waitFor('the pack list to be fetched', async () => listRequests().length > 0, 30000);
	await sleep(1500);
	await screenshot('01_pack_list');
	check('the pack listing was requested cross-origin', listRequests().length > 0);

	console.log('\nClicking Download on the first pack…');
	await clickAt(ACTION_BUTTON_X, FIRST_ROW_Y);
	await sleep(1000);
	await screenshot('02_downloading');

	check('a pack download was started', packRequests().length === 1);

	console.log('Waiting for the pack to download and open…');
	await waitFor('the language database to open', async () =>
		consoleLines.some((l) => l.includes('Opened database successfully')), 300000);
	console.log('  downloaded, stored, and opened by SQLite');
	await sleep(2500);
	await screenshot('03_checker_screen');
	check('the pack was downloaded exactly once', packRequests().length === 1);

	// Writing the pack and *persisting* it are not the same moment. The engine's
	// filesystem sync to IndexedDB is asynchronous and takes seconds for a pack
	// this size — measured at 5-10 s for 41 MB — and reloading before it lands
	// throws the pack away. Waiting for storage to actually grow is what makes
	// this test deterministic; without it, it passes on a fast local server and
	// fails against a real host, purely on timing.
	console.log('\nWaiting for the filesystem sync to reach IndexedDB…');
	const settleStart = Date.now();
	let lastUsage = -1;
	let steady = 0;
	await waitFor('IndexedDB usage to settle', async () => {
		const usage = await indexedDbBytes();
		if (usage === lastUsage && usage > MIN_PERSISTED_BYTES) {
			steady++;
		} else {
			steady = 0;
		}
		lastUsage = usage;
		return steady >= 2;
	}, 120000, 1000);
	console.log(`  persisted ${Math.round(lastUsage / 1048576)} MB after ${Math.round((Date.now() - settleStart) / 1000)} s`);

	// The real test of persistence: come back to the page as a tester would
	// tomorrow, and open the same pack without fetching a single byte of it.
	console.log('\nReloading the page — the pack must survive in IndexedDB…');
	const beforeReload = packRequests().length;
	await send('Page.navigate', { url: appUrl });
	await waitForEngine();
	await sleep(2500);
	await screenshot('04_after_reload');

	console.log('Clicking Open on the stored pack…');
	const openedBefore = consoleLines.filter((l) => l.includes('Opened database successfully')).length;
	await clickAt(ACTION_BUTTON_X, FIRST_ROW_Y);
	await waitFor('the stored pack to open', async () =>
		consoleLines.filter((l) => l.includes('Opened database successfully')).length > openedBefore,
		120000);
	await sleep(2000);
	await screenshot('05_reopened_from_storage');

	check('the stored pack opened after a reload', true);
	check('no pack was re-downloaded after the reload',
			packRequests().length === beforeReload);

	const errors = consoleLines.filter((l) => /SCRIPT ERROR|Cannot call|error\]/i.test(l));
	if (errors.length) {
		console.log('\nError lines in the console:');
		for (const line of errors) console.log(`  ${line}`);
		failures += errors.length;
	}

	console.log(`\nPack requests seen: ${packRequests().length}`);
	for (const url of packRequests()) console.log(`  ${url.split('?')[0]}`);

	if (failures) {
		console.log(`\n${failures} check(s) failed.`);
		process.exit(1);
	}
	console.log('\nWeb download run passed.');
	process.exit(0);
}

main().catch((error) => {
	console.error(`\nFAILED: ${error.message}`);
	if (consoleLines.length) {
		console.error('Console output:');
		for (const line of consoleLines) console.error(`  ${line}`);
	}
	process.exit(1);
});
