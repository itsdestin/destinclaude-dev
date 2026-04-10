#!/usr/bin/env bash
# Setup script for the destinclaude-dev workspace.
# Clones or pulls the latest from all project repos into the current directory.

set -euo pipefail

REPOS=(
  "itsdestin/destincode:master"
  "itsdestin/destinclaude:master"
  "itsdestin/destinclaude-admin:master"
  "itsdestin/destinclaude-themes:main"
  "itsdestin/destincode-marketplace:master"
)

for entry in "${REPOS[@]}"; do
  repo="${entry%%:*}"
  branch="${entry##*:}"
  name="${repo##*/}"

  if [ -d "$name/.git" ]; then
    echo "Updating $name..."
    git -C "$name" fetch origin
    git -C "$name" pull origin "$branch"
  else
    echo "Cloning $name..."
    git clone --branch "$branch" "https://github.com/$repo.git" "$name"
  fi
done

echo ""
echo "Workspace ready. All repos are up to date."
