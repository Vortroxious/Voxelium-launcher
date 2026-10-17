#!/usr/bin/env bash
# Copies a game install made on the Mac (zalith-cli install <id> --root build/gamedata,
# every file hash-checked) into the app's data container on a USB-connected iPhone,
# instead of re-downloading ~730 MB on the phone after each reinstall.
#
#   scripts/push-gamedata.sh [device-udid] [bundle-id]
#
# The app must be installed and opened once (so its data container exists).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/gamedata/minecraft"
DEVICE="${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ && /physical/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)}"
BUNDLE="${2:-$(xcrun devicectl device info apps --device "$DEVICE" 2>/dev/null | awk '/io\.github\.zalithios\.launcher/ {for (i=1;i<=NF;i++) if ($i ~ /^io\.github\.zalithios\.launcher/) print $i}' | head -1)}"
DEST="Library/Application Support/ZalithIOS/minecraft"

[ -d "$SRC/versions" ] || { echo "no game install in $SRC (run zalith-cli install first)" >&2; exit 1; }
[ -n "$DEVICE" ] || { echo "no connected iPhone found" >&2; exit 1; }
[ -n "$BUNDLE" ] || { echo "Zalith iOS is not installed on $DEVICE" >&2; exit 1; }

echo "==> $SRC ($(du -sh "$SRC" | cut -f1)) -> $DEVICE $BUNDLE:$DEST"
xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" --source "$SRC" --destination "$DEST"
echo "==> versions on device:"
xcrun devicectl device info files --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" --subdirectory "$DEST/versions" 2>/dev/null | grep -E "^[^ ]+ " | head
