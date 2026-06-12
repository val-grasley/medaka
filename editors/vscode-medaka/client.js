// Phase 34 — minimal VS Code / Cursor language client.
// Spawns `medaka lsp` and connects over stdio.
//
// The NATIVE `medaka lsp` reads the stdlib (runtime.mdk / core.mdk) from disk via
// MEDAKA_ROOT (unlike the OCaml server, which embeds the prelude). So we set
// MEDAKA_ROOT for the spawned server: `medaka.root` config if set, else the first
// workspace folder. Without it the native server can't find stdlib and exits.

const { workspace } = require('vscode');
const {
  LanguageClient,
  TransportKind,
} = require('vscode-languageclient/node');

let client;

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

  const exec = { command, args: ['lsp'], transport: TransportKind.stdio, options: { env } };
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
