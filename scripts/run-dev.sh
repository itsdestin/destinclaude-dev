#!/bin/bash
# Run a dev instance of YouCoded alongside your built/installed app.
# See docs/local-dev.md for what this isolates and what it shares.
set -euo pipefail

cd "$(dirname "$0")/.."

# Shifts every port youcoded controls (Vite 5173 → 5223, remote 9900 → 9950).
# First dev instance uses offset 50; a second concurrent dev could use 100, etc.
export YOUCODED_PORT_OFFSET="${YOUCODED_PORT_OFFSET:-50}"

# Splits Electron userData → %APPDATA%/youcoded-dev/ so dev's localStorage,
# window bounds, and cache don't clobber the built app's.
export YOUCODED_PROFILE=dev

echo "Starting YouCoded dev (port offset: $YOUCODED_PORT_OFFSET)..."
echo "  Vite:          http://localhost:$((5173 + YOUCODED_PORT_OFFSET))"
echo "  Remote server: port $((9900 + YOUCODED_PORT_OFFSET)) (if enabled in dev)"
echo ""
cd youcoded/desktop
npm run dev
