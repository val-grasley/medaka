// Phase 34 — minimal VS Code / Cursor language client.
// Spawns `medaka lsp` and connects over stdio.
//
// The NATIVE `medaka lsp` reads the stdlib (runtime.mdk / core.mdk) from disk via
// MEDAKA_ROOT (unlike the OCaml server, which embeds the prelude). So we set
// MEDAKA_ROOT for the spawned server: `medaka.root` config if set, else the first
// workspace folder. Without it the native server can't find stdlib and exits.
//
// We also redirect the server's STDERR into the same append-only log the server
// writes its own recv/handled trace to ($MEDAKA_LSP_LOG, else /tmp/medaka-lsp.log).
// A real panic (`mdk_panic` writes its message to stderr then exit(1)) then lands
// in the log right after the unfinished `recv` line — so the crash tripwire can
// tell a genuine panic (a raw, non-timestamped stderr line) apart from a normal
// Cursor server restart / window reload (which produces no stderr). stdin/stdout
// stay on the pipe for JSON-RPC; only fd 2 is redirected.

const { workspace } = require('vscode');
const {
  LanguageClient,
  TransportKind,
} = require('vscode-languageclient/node');

let client;

// POSIX single-quote a string for use inside `sh -c`.
function shq(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

function activate(_context) {
  const config = workspace.getConfiguration('medaka');
  const command = config.get('serverPath', 'medaka');

  // MEDAKA_ROOT: explicit config wins; otherwise the first workspace folder.
  const folders = workspace.workspaceFolders;
  const root =
    config.get('root', '') ||
    (folders && folders.length > 0 ? folders[0].uri.fsPath : undefined);

  const env = Object.assign({}, process.env);
  if (root) env.MEDAKA_ROOT = root;

  // Same log the server appends its trace to; force it so stderr and the trace
  // interleave in one file.
  const logPath = process.env.MEDAKA_LSP_LOG || '/tmp/medaka-lsp.log';
  env.MEDAKA_LSP_LOG = logPath;

  // `exec` replaces the shell with the server (so SIGTERM on reload reaches it
  // directly); `2>>` appends the server's stderr to the log.
  const shellCmd = `exec ${shq(command)} lsp 2>>${shq(logPath)}`;
  const exec = {
    command: 'sh',
    args: ['-c', shellCmd],
    transport: TransportKind.stdio,
    options: { env },
  };
  const serverOptions = { run: exec, debug: exec };

  const clientOptions = {
    documentSelector: [{ scheme: 'file', language: 'medaka' }],
  };

  client = new LanguageClient(
    'medaka',
    'Medaka Language Server',
    serverOptions,
    clientOptions,
  );

  client.start();
}

function deactivate() {
  if (!client) return undefined;
  return client.stop();
}

module.exports = { activate, deactivate };
