#!/usr/bin/env bash
# Install or refresh the Medaka VS Code / Cursor extension.
# Run from anywhere inside the repo:  editors/install-vscode.sh
# Or via alias:  medaka-ext

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_SRC="$SCRIPT_DIR/vscode-medaka"
EXT_ID="medaka-lang.medaka-0.1.0"

install_for() {
  local label="$1"
  local ext_dir="$2"

  if [[ ! -d "$ext_dir" ]]; then
    echo "  $label: extensions dir not found, skipping"
    return
  fi

  local dest="$ext_dir/$EXT_ID"
  rm -rf "$dest"
  cp -r "$EXT_SRC" "$dest"

  # Clear the obsolete flag for this extension so the editor picks it up.
  local obsolete="$ext_dir/.obsolete"
  if [[ -f "$obsolete" ]]; then
    python3 - "$obsolete" "$EXT_ID" <<'PY'
import sys, json
path, eid = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data.pop(eid, None)
with open(path, "w") as f:
    json.dump(data, f)
PY
  fi

  echo "  $label: installed -> $dest"
}

echo "Installing Medaka extension ($EXT_ID)..."
install_for "Cursor"  "$HOME/.cursor/extensions"
install_for "VS Code" "$HOME/.vscode/extensions"
echo "Done. Restart your editor to pick up changes."
