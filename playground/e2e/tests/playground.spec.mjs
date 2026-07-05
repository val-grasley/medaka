// tests/playground.spec.mjs — Medaka CM6 playground end-to-end checks.
//
// Drives the SYSTEM Google Chrome (channel: 'chrome') against a real browser —
// no headless-only "logic" test, no Playwright browser download (blocked by
// TLS interception on this machine; see playground/e2e/README.md). Requires:
//   - node v24+ on PATH (system v20 can't run the finalized-WasmGC module)
//   - playground/dist/{playground.wasm,runtime.mdk,core.mdk} already built
//     (bash playground/build_playground_wasm.sh) — this harness does NOT build it
//   - a running static server (see lib/server.mjs), started by run.sh
//
// Usage: node tests/playground.spec.mjs <base-url> <screenshots-dir>
import { chromium } from 'playwright';

const [, , BASE_URL, SCREENSHOT_DIR] = process.argv;
if (!BASE_URL || !SCREENSHOT_DIR) {
  console.error('usage: node playground.spec.mjs <base-url> <screenshots-dir>');
  process.exit(2);
}

const DEFAULT_SAMPLE =
  'main =\n  println (sum [1,2,3,4,5])\n  println "hello from Medaka!"\n';
const TYPE_ERROR_SAMPLE = 'main = println (1 + "hello")\n';

let failures = 0;
function check(name, cond, detail) {
  if (cond) {
    console.log(`  PASS  ${name}`);
  } else {
    failures++;
    console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`);
  }
}

async function main() {
  const browser = await chromium.launch({ channel: 'chrome' });
  const page = await (await browser.newContext()).newPage();
  const pageErrors = [];
  page.on('pageerror', (e) => pageErrors.push(e.message));

  try {
    console.log(`Loading ${BASE_URL} ...`);
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });

    // ── Test 1: page loads + CM6 mounts ────────────────────────────────────
    console.log('Test: CM6 editor mounts');
    await page.waitForSelector('.cm-editor .cm-content', { timeout: 15000 });
    const noTextarea = !(await page.$('#editor textarea'));
    const hasCmEditor = !!(await page.$('.cm-editor'));
    check('CM6 .cm-editor present, legacy textarea gone', noTextarea && hasCmEditor);
    await page.screenshot({ path: `${SCREENSHOT_DIR}/01_loaded.png` });

    // ── Test 2: syntax highlighting active ─────────────────────────────────
    console.log('Test: syntax highlighting');
    const spanCount = await page.$$eval('.cm-content span', (ss) => ss.length);
    const distinctColors = await page.$$eval('.cm-content span', (ss) => {
      const colors = new Set(ss.map((s) => getComputedStyle(s).color).filter(Boolean));
      return colors.size;
    });
    check(`>5 highlighted spans (got ${spanCount})`, spanCount > 5);
    check(`>=3 distinct token colors (got ${distinctColors})`, distinctColors >= 3);
    await page.screenshot({ path: `${SCREENSHOT_DIR}/02_highlighting.png` });

    // ── Test 3: default sample runs, stdout shows expected output ─────────
    console.log('Test: default sample runs');
    await page.evaluate((src) => {
      const v = window.__mdkView;
      v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: src } });
    }, DEFAULT_SAMPLE);
    await page.waitForSelector('#run-btn:not([disabled])', { timeout: 15000 });
    await page.click('#run-btn');
    await page.waitForFunction(
      () => document.getElementById('stdout')?.textContent?.includes('hello'),
      null,
      { timeout: 30000 },
    );
    const stdout = (await page.$eval('#stdout', (el) => el.textContent)).trim();
    check('stdout contains "hello from Medaka!"', stdout.includes('hello from Medaka!'), stdout);
    check('stdout contains sum result "15"', stdout.includes('15'), stdout);
    await page.screenshot({ path: `${SCREENSHOT_DIR}/03_run_output.png` });

    // ── Test 4: type error -> inline squiggle + gutter marker + problems pane
    console.log('Test: type-error squiggle');
    await page.evaluate((src) => {
      const v = window.__mdkView;
      v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: src } });
    }, TYPE_ERROR_SAMPLE);
    await page.waitForSelector('.cm-lintRange-error, .cm-lint-marker-error', { timeout: 8000 });
    const hasSquiggle = !!(await page.$('.cm-lintRange-error'));
    const hasGutterMarker = !!(await page.$('.cm-lint-marker-error'));
    const problemsText = (await page.$eval('#problems', (el) => el.textContent).catch(() => ''));
    check('inline squiggle (.cm-lintRange-error) present', hasSquiggle);
    check('gutter marker (.cm-lint-marker-error) present', hasGutterMarker);
    check(
      'problems pane reports "No impl of Num for String"',
      problemsText.includes('No impl of Num for String'),
      problemsText.slice(0, 200),
    );
    await page.screenshot({ path: `${SCREENSHOT_DIR}/04_squiggle.png` });

    if (pageErrors.length) {
      console.log('Uncaught page errors observed during run:', pageErrors);
    }
  } catch (e) {
    console.error('Harness error:', e.message);
    failures++;
    try { await page.screenshot({ path: `${SCREENSHOT_DIR}/ERROR.png` }); } catch {}
  } finally {
    await browser.close();
  }

  if (failures === 0) {
    console.log('\nALL CHECKS PASSED');
    process.exit(0);
  } else {
    console.log(`\n${failures} CHECK(S) FAILED`);
    process.exit(1);
  }
}

main();
