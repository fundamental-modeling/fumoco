// This file is part of Fumoco.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Holger Peters -- see the LICENSE file.

// Renders every docs/**/figures/*.fumoco.json with Fumoco itself: serves
// the production build (`vite preview` over dist/), opens each model's
// first view in headless Chrome/Chromium and saves what the app's own
// "Export SVG" produces next to the model, as <name>.svg.
//
//   npm run docs:figures            (builds first)
//   CHROME=/path/to/chrome npm run docs:figures
//
// Talks to the browser over the DevTools protocol directly -- a few lines
// of WebSocket instead of a Puppeteer dependency.

/* eslint-disable n/no-unsupported-features/node-builtins --
   this docs script (not the app) needs Node >= 22.4 for the built-in
   fetch and WebSocket; checked at startup below. */
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, readdirSync, writeFileSync, mkdtempSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const PORT = 4174;
const DEBUG_PORT = 9444;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function figureModels(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return figureModels(path);
    return dir.endsWith('figures') && entry.name.endsWith('.fumoco.json')
      ? [path]
      : [];
  });
}

function chromeBinary() {
  const candidates = [
    process.env.CHROME,
    'chromium',
    'chromium-browser',
    'google-chrome',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ].filter(Boolean);
  const found = candidates.find(
    (c) => spawnSync(c, ['--version'], { stdio: 'ignore' }).status === 0,
  );
  if (!found) throw new Error('no Chrome/Chromium found; set $CHROME');
  return found;
}

async function waitFor(url) {
  for (let i = 0; i < 100; i++) {
    try {
      if ((await fetch(url)).ok) return;
    } catch {
      // not up yet
    }
    await sleep(200);
  }
  throw new Error(`${url} did not come up`);
}

async function devtools() {
  const tabs = await (
    await fetch(`http://127.0.0.1:${DEBUG_PORT}/json`)
  ).json();
  const ws = new WebSocket(
    tabs.find((t) => t.type === 'page').webSocketDebuggerUrl,
  );
  await new Promise((r) => (ws.onopen = r));
  let id = 0;
  const pending = new Map();
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id) pending.get(d.id)?.(d);
  };
  const send = (method, params = {}) =>
    new Promise((resolve) => {
      pending.set(++id, resolve);
      ws.send(JSON.stringify({ id, method, params }));
    });
  const evaluate = async (expression) => {
    const { result } = await send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.exception?.description);
    }
    return result.result.value;
  };
  return { ws, send, evaluate };
}

async function render(browser, url, modelPath) {
  const model = readFileSync(modelPath, 'utf8');
  const viewName = Object.values(JSON.parse(model).views)[0].name;
  await browser.send('Page.navigate', { url });
  await sleep(2000);
  await browser.evaluate(
    `localStorage.setItem('fumoco:autosave', ${JSON.stringify(model)})`,
  );
  await browser.send('Page.reload');
  await sleep(2500);
  await browser.evaluate(`document.fonts.ready`);
  const clicked = await browser.evaluate(`(() => {
    const row = [...document.querySelectorAll('*')].find(
      (e) => e.children.length === 0 && e.textContent.trim() === ${JSON.stringify(viewName)});
    row?.click();
    return Boolean(row);
  })()`);
  if (!clicked) throw new Error(`view "${viewName}" not found`);
  await sleep(1000);
  // Let the app export as usual, but catch its download link.
  return browser.evaluate(`(async () => {
    let href;
    HTMLAnchorElement.prototype.click = function () { href = this.href; };
    URL.revokeObjectURL = () => {};
    [...document.querySelectorAll('button')]
      .find((b) => b.textContent.trim() === 'Export SVG').click();
    return (await fetch(href)).text();
  })()`);
}

if (typeof WebSocket === 'undefined') {
  throw new Error('render-figures needs Node >= 22.4 (built-in WebSocket)');
}

const models = figureModels(join(root, 'docs'));
const preview = spawn(
  'npx',
  ['vite', 'preview', '--port', String(PORT), '--strictPort'],
  {
    cwd: root,
    stdio: 'ignore',
  },
);
const chrome = spawn(
  chromeBinary(),
  [
    '--headless=new',
    '--no-sandbox',
    `--remote-debugging-port=${DEBUG_PORT}`,
    `--user-data-dir=${mkdtempSync(join(tmpdir(), 'fumoco-figures-'))}`,
    'about:blank',
  ],
  { stdio: 'ignore' },
);
try {
  const url = `http://localhost:${PORT}/`;
  await waitFor(url);
  await waitFor(`http://127.0.0.1:${DEBUG_PORT}/json`);
  const browser = await devtools();
  await browser.send('Runtime.enable');
  for (const modelPath of models) {
    const svg = await render(browser, url, modelPath);
    const out = modelPath.replace(/\.fumoco\.json$/, '.svg');
    writeFileSync(out, svg.endsWith('\n') ? svg : `${svg}\n`);
    console.log(`${basename(modelPath)} -> ${basename(out)}`);
  }
  browser.ws.close();
} finally {
  chrome.kill();
  preview.kill();
}
