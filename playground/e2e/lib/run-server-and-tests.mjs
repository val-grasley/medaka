// lib/run-server-and-tests.mjs — orchestrates: start static server -> run
// the Playwright test spec as a child process -> always tear the server down.
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { startServer } from './server.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const [, , PLAYGROUND_ROOT, PORT_ARG, SCREENSHOT_DIR] = process.argv;
const PORT = parseInt(PORT_ARG, 10);

let server;
try {
  server = await startServer(PORT);
  console.log(`Static server up at ${server.url}`);

  const testFile = join(HERE, '..', 'tests', 'playground.spec.mjs');
  const status = await new Promise((resolve) => {
    const child = spawn(process.execPath, [testFile, server.url, SCREENSHOT_DIR], {
      cwd: PLAYGROUND_ROOT,
      stdio: 'inherit',
    });
    child.on('exit', (code) => resolve(code ?? 1));
  });
  process.exitCode = status;
} finally {
  if (server) {
    console.log('Tearing down static server...');
    await server.stop();
  }
}
