// lib/server.mjs — spawn/tear down the playground's own static dev server
// (playground/server.js) for the duration of the e2e run.
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const PLAYGROUND_ROOT = join(HERE, '..', '..'); // playground/e2e/lib -> playground/

export async function startServer(port) {
  const child = spawn(process.execPath, [join(PLAYGROUND_ROOT, 'server.js')], {
    cwd: PLAYGROUND_ROOT,
    env: { ...process.env, PORT: String(port) },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let out = '';
  child.stdout.on('data', (d) => { out += d.toString(); });
  child.stderr.on('data', (d) => { out += d.toString(); });

  // Poll until the server actually answers, rather than trusting stdout timing.
  const url = `http://127.0.0.1:${port}/`;
  const deadline = Date.now() + 10000;
  let ready = false;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(url);
      if (res.ok) { ready = true; break; }
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  if (!ready) {
    child.kill();
    throw new Error(`playground/server.js did not come up on ${url}. Output so far:\n${out}`);
  }
  return {
    url,
    stop: () => new Promise((resolve) => {
      child.once('exit', resolve);
      child.kill();
      // Fallback in case the child ignores SIGTERM.
      setTimeout(() => { try { child.kill('SIGKILL'); } catch {} }, 2000);
    }),
  };
}
