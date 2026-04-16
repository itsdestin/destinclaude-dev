#!/usr/bin/env bash
# Setup script for the youcoded-dev workspace.
# Clones or pulls the latest from all project repos into the current directory.

set -euo pipefail

REPOS=(
  "itsdestin/youcoded:master"
  "itsdestin/youcoded-core:master"
  "itsdestin/youcoded-admin:master"
  "itsdestin/wecoded-themes:main"
  "itsdestin/wecoded-marketplace:master"
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
