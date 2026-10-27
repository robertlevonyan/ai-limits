#!/bin/bash
# Usage: scripts/make-dmg.sh "path/to/AI Limits.app" "output.dmg"
# Builds a drag-to-Applications disk image.
set -euo pipefail
APP="$1"; OUT="$2"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "AI Limits" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
rm -rf "$STAGE"
