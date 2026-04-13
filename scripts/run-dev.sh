#!/bin/bash
# Run a dev instance of DestinCode alongside your built/installed app.
# See docs/local-dev.md for what this isolates and what it shares.
set -euo pipefail

cd "$(dirname "$0")/.."

# Shifts every port destincode controls (Vite 5173 → 5223, remote 9900 → 9950).
# First dev instance uses offset 50; a second concurrent dev could use 100, etc.
export DESTINCODE_PORT_OFFSET="${DESTINCODE_PORT_OFFSET:-50}"

# Splits Electron userData → %APPDATA%/destincode-dev/ so dev's localStorage,
# window bounds, and cache don't clobber the built app's.
export DESTINCODE_PROFILE=dev

echo "Starting DestinCode dev (port offset: $DESTINCODE_PORT_OFFSET)..."
echo "  Vite:          http://localhost:$((5173 + DESTINCODE_PORT_OFFSET))"
echo "  Remote server: port $((9900 + DESTINCODE_PORT_OFFSET)) (if enabled in dev)"
echo ""
cd destincode/desktop
npm run dev
