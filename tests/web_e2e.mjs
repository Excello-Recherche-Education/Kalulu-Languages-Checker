// Drives the exported web build in headless Chrome and checks the parts that
// only exist in a browser: reading a pack the tester picked, opening its
// SQLite database on the browser filesystem, and downloading the CSV report.
//
//   node tests/web_e2e.mjs <app url> <pack url> <download dir> [shot dir]
//
// Chrome must already be listening on 127.0.0.1:9222 with remote debugging.

const [appUrl, packUrl, downloadDir, shotDir] = process.argv.slice(2);
if (!appUrl || !packUrl || !downloadDir) {
	console.error('usage: node tests/web_e2e.mjs <app url> <pack url> <download dir> [shot dir]');
	process.exit(2);
}

const consoleLines = [];
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
		expression,
		awaitPromise,
		returnByValue: true,
		userGesture: true,
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
	const path = `${shotDir}/${name}.png`;
	await writeFile(path, Buffer.from(data, 'base64'));
	console.log(`  saved ${path}`);
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
	});

	await send('Runtime.enable');
	await send('Log.enable');
	await send('Page.enable');
	await send('Browser.setDownloadBehavior', {
		behavior: 'allow', downloadPath: downloadDir, eventsEnabled: true,
	});

	// The checker keeps the pack and the tester's report in IndexedDB, so a
	// repeat run would start with a pack already loaded and reports already
	// filed. Clear it so every run starts as a first visit would.
	const origin = new URL(appUrl).origin;
	await send('Storage.clearDataForOrigin', {
		origin, storageTypes: 'indexeddb,local_storage,cache_storage',
	});

	console.log(`Loading ${appUrl}`);
	await send('Page.navigate', { url: appUrl });

	console.log('Waiting for the engine to start…');
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
	console.log('  engine is running and the picker is installed');
	await screenshot('01_load_screen');

	console.log(`Feeding ${packUrl} to the file input…`);
	const picked = await evaluate(`
		(async function () {
			var response = await fetch(${JSON.stringify(packUrl)});
			var buffer = await response.arrayBuffer();
			var file = new File([buffer], 'fr_FR.zip', {type: 'application/zip'});
			var input = document.querySelector('input[type=file]');
			var transfer = new DataTransfer();
			transfer.items.add(file);
			input.files = transfer.files;
			input.dispatchEvent(new Event('change'));
			return {megabytes: Math.round(buffer.byteLength / 1048576)};
		})();
	`);
	console.log(`  handed over ${picked.megabytes} MB`);

	console.log('Waiting for the pack to be read and opened…');
	await waitFor('the browser read to finish', async () =>
		await evaluate("window.__kaluluPicker.state === 'idle'"), 180000);
	console.log('  the engine read the whole file');

	const opened = await waitFor('the language database to open', async () =>
		consoleLines.some((line) => line.includes('Opened database successfully')), 120000);
	console.log(`  SQLite opened the database on the browser filesystem: ${opened}`);
	await sleep(3000);
	await screenshot('02_checker_screen');

	// The interface is drawn on a canvas, so there is nothing to query for a
	// position: these are measured against the layout, with the footer taken
	// from the bottom of the viewport rather than assumed to be 800px down.
	const viewport = await evaluate('({w: window.innerWidth, h: window.innerHeight})');
	const FIRST_ROW_Y = 156;
	const PROBLEM_CHECKBOX_X = 566;
	const FINISH_BUTTON = { x: viewport.w - 146, y: viewport.h - 34 };
	// Measured from 04_thank_you.png, where the button spans y 528–568. Unlike
	// the footer above, this one is laid out from the top of a centred column,
	// so it does not follow the viewport height and is quoted outright.
	const DOWNLOAD_BUTTON_Y = 548;

	console.log('Reporting a problem on the first row…');
	await clickAt(PROBLEM_CHECKBOX_X, FIRST_ROW_Y);
	await screenshot('03_problem_ticked');

	console.log('Clicking "Finish testing and send report"…');
	await clickAt(FINISH_BUTTON.x, FINISH_BUTTON.y);
	await sleep(2500);
	await screenshot('04_thank_you');

	const { readdir, readFile } = await import('node:fs/promises');
	// Chrome creates the download directory only when it first writes to it, so
	// "not there at all" is the normal answer before anything is downloaded —
	// and is the answer the unasked-download check below is hoping for.
	const csvsPresent = async () => {
		try {
			return (await readdir(downloadDir)).filter((f) => f.endsWith('.csv'));
		} catch (error) {
			if (error.code === 'ENOENT') return [];
			throw error;
		}
	};

	// Arriving here must not download anything: the tester may be about to press
	// "Send my report", and a file they did not ask for invites them to email a
	// second copy of what we already have.
	await sleep(2000);
	const unasked = await csvsPresent();
	if (unasked.length) {
		console.log(`FAILED: ${unasked.join(', ')} was downloaded without being asked for`);
		process.exit(1);
	}
	console.log('  ok    nothing was downloaded unasked');

	// The buttons row is centred under a 720px column, and on the web the
	// "Show me the file" button is hidden — so the row is the 240px download
	// button and the 180px mail button with 12px between them. Re-measure from
	// 04_thank_you.png if a click ever lands somewhere unexpected.
	const DOWNLOAD_BUTTON = { x: Math.round(viewport.w / 2) - 96, y: DOWNLOAD_BUTTON_Y };

	console.log('Clicking "Download the report"…');
	await clickAt(DOWNLOAD_BUTTON.x, DOWNLOAD_BUTTON.y);
	await screenshot('05_download_requested');

	const files = await waitFor('the CSV download to appear', async () => {
		const found = await csvsPresent();
		return found.length > 0 ? found : false;
	}, 30000);
	console.log(`  downloaded: ${files.join(', ')}`);
	const csv = await readFile(`${downloadDir}/${files[0]}`, 'utf8');
	console.log('--- CSV ---');
	console.log(csv.trimEnd());
	console.log('-----------');

	console.log('\nGodot console output:');
	for (const line of consoleLines) console.log(`  ${line}`);

	const errors = consoleLines.filter((l) =>
		/SCRIPT ERROR|ERROR:|Cannot call|error\]/i.test(l));
	if (errors.length) {
		console.log(`\n${errors.length} error line(s) in the console.`);
		process.exit(1);
	}
	console.log('\nWeb end-to-end run passed.');
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
