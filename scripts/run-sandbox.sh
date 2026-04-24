#!/bin/bash
# Launch a dev instance of YouCoded that boots straight into the ToolCard
# sandbox (?mode=tool-sandbox). Useful when iterating on ToolCard/ToolBody
# views — no DevTools redirect dance needed.
#
# See docs/superpowers/plans/2026-04-24-tool-card-sandbox.md and
# scripts/run-dev.sh for details.
set -euo pipefail

cd "$(dirname "$0")/.."

# Same offset + profile as run-dev.sh. Keeps the dev instance isolated from
# the built/installed app.
export YOUCODED_PORT_OFFSET="${YOUCODED_PORT_OFFSET:-50}"
export YOUCODED_PROFILE=dev

# This is the new env var — lets the Electron main process loadURL() at the
# sandbox directly instead of the default Vite root.
export YOUCODED_DEV_URL="http://localhost:$((5173 + YOUCODED_PORT_OFFSET))/?mode=tool-sandbox"

echo "Starting YouCoded dev in sandbox mode (port offset: $YOUCODED_PORT_OFFSET)..."
echo "  Vite:   http://localhost:$((5173 + YOUCODED_PORT_OFFSET))"
echo "  Loads: $YOUCODED_DEV_URL"
echo ""
cd youcoded/desktop
npm run dev
