# Medaka — VS Code extension

Syntax highlighting and Language Server Protocol support for `.mdk` files.

## Install

The `editors/install-vscode.sh` helper copies this directory into VS Code's
and Cursor's extension folders.

After installing, ensure the `medaka` binary is on your `$PATH`. The
language client launches `medaka lsp` as a subprocess for diagnostics.

If your binary lives elsewhere, set `medaka.serverPath` in the VS Code
settings to the full path.

## Features

- Syntax highlighting (TextMate grammar).
- Error diagnostics from the parser, resolver, and type checker, refreshed
  on every edit. Squiggle ranges underline the offending expression.

The server runs as `medaka lsp` over stdio. The native `medaka lsp` server
advertises and implements diagnostics, hover (inferred types for top-level and
local bindings), completion (prefix-filtered names from the typecheck env),
go-to-definition, document highlight, and inlay hints. The client starts the
server and negotiates capabilities automatically. (verified done 2026-06-22)

## Building the client

The client JavaScript depends on `vscode-languageclient`. If you cloned this
repo and want a working client extension, run:

```
cd editors/vscode-medaka
npm install
```

The `dependencies` block in `package.json` pins the version VS Code
extension hosts know how to load. Without `npm install`, VS Code will report
that `vscode-languageclient` is missing on activation.
