#!/bin/bash
set -euo pipefail

SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
BIN_DIR="$HOME/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$SYSTEMD_USER_DIR" "$BIN_DIR"

cp "$SCRIPT_DIR/claude-resident" "$BIN_DIR/claude-resident"
chmod +x "$BIN_DIR/claude-resident"

CR_LINK="$BIN_DIR/cr"
if [ -e "$CR_LINK" ] && [ "$(readlink -f "$CR_LINK")" != "$(readlink -f "$BIN_DIR/claude-resident")" ]; then
  echo "WARN: $CR_LINK already exists and points elsewhere. Resolve it manually." >&2
  exit 1
else
  ln -sf "$BIN_DIR/claude-resident" "$CR_LINK"
fi

for svc in claude-resident@.service \
           claude-resident-restart@.service \
           claude-resident-restart@.timer \
           claude-resident-health@.service \
           claude-resident-health@.timer; do
  cp "$SCRIPT_DIR/$svc" "$SYSTEMD_USER_DIR/"
done

systemctl --user daemon-reload

echo "Install complete."
echo "Next:"
echo "  1. Configure ~/.config/claude-resident/<name>/CLAUDE.md and memory/"
echo "  2. systemctl --user enable --now claude-resident@<name>.service"
echo "  3. claude-resident <name> check"
