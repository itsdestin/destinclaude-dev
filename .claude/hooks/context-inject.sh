#!/usr/bin/env bash
# SessionStart hook: inject dynamic project state into Claude's context.
#
# For multi-repo workspaces (youcoded-dev), shows recent commits, current
# branches, uncommitted changes, and active worktrees per sub-repo.
# For single-repo projects, shows the same for the current repo.
#
# Plain text output on stdout is injected into Claude's context at session start.

set -euo pipefail

# Claude Code sets CLAUDE_PROJECT_DIR when running in a project; fallback to cwd
WORKSPACE="${CLAUDE_PROJECT_DIR:-$(pwd)}"

[[ ! -d "$WORKSPACE" ]] && exit 0

collect_repo_state() {
    local repo_dir="$1"
    local repo_name="$2"

    [[ ! -d "$repo_dir/.git" ]] && return

    local branch recent dirty dirty_count
    branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null || echo "detached")
    recent=$(git -C "$repo_dir" log --oneline -3 2>/dev/null || echo "  (no commits)")
    dirty=$(git -C "$repo_dir" status --porcelain 2>/dev/null | head -5)

    echo "### $repo_name (on \`$branch\`)"
    echo "Recent commits:"
    echo '```'
    echo "$recent" | sed 's/^/  /'
    echo '```'

    if [[ -n "$dirty" ]]; then
        dirty_count=$(git -C "$repo_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        echo "Uncommitted changes (${dirty_count} files, showing first 5):"
        echo '```'
        echo "$dirty" | sed 's/^/  /'
        echo '```'
    fi
    echo ""
}

# Detect multi-repo workspace by checking for known sub-repos
SUB_REPOS=()
for candidate in youcoded youcoded-core youcoded-admin wecoded-themes wecoded-marketplace; do
    if [[ -d "$WORKSPACE/$candidate/.git" ]]; then
        SUB_REPOS+=("$candidate")
    fi
done

if [[ ${#SUB_REPOS[@]} -gt 0 ]]; then
    # Multi-repo workspace
    echo "## Project State (auto-generated at session start)"
    echo ""
    for repo in "${SUB_REPOS[@]}"; do
        collect_repo_state "$WORKSPACE/$repo" "$repo"
    done

    # Active worktrees
    WORKTREES_FOUND=0
    while IFS= read -r -d '' dir; do
        if [[ $WORKTREES_FOUND -eq 0 ]]; then
            echo "### Active worktrees"
            WORKTREES_FOUND=1
        fi
        echo "  - $(basename "$dir")"
    done < <(find "$WORKSPACE" -maxdepth 1 -type d \( -name "*-worktree*" -o -name "*-phase*" -o -name "*-decoupling" \) -print0 2>/dev/null || true)
    [[ $WORKTREES_FOUND -eq 1 ]] && echo ""
elif [[ -d "$WORKSPACE/.git" ]]; then
    # Single-repo project
    echo "## Project State (auto-generated at session start)"
    echo ""
    collect_repo_state "$WORKSPACE" "$(basename "$WORKSPACE")"
fi

# --- Staleness detection ---
# Flag stale docs or open knowledge debt. Suggests running /audit when appropriate.
AUDIT_FILE="$WORKSPACE/docs/AUDIT.md"
DEBT_FILE="$WORKSPACE/docs/knowledge-debt.md"

if [[ -f "$AUDIT_FILE" ]]; then
    # Prefer git commit time; fallback to filesystem mtime if untracked or no commits
    AUDIT_CTIME=$(git -C "$WORKSPACE" log -1 --format=%ct -- docs/AUDIT.md 2>/dev/null || true)
    if [[ -z "$AUDIT_CTIME" ]]; then
        # Untracked or no commits yet — use filesystem modification time
        AUDIT_CTIME=$(stat -c %Y "$AUDIT_FILE" 2>/dev/null || stat -f %m "$AUDIT_FILE" 2>/dev/null || echo "")
    fi
    if [[ -n "$AUDIT_CTIME" ]]; then
        NOW_EPOCH=$(date +%s)
        AUDIT_AGE_DAYS=$(( (NOW_EPOCH - AUDIT_CTIME) / 86400 ))
        if [[ $AUDIT_AGE_DAYS -gt 60 ]]; then
            echo "### ⚠️ Documentation staleness"
            echo "docs/AUDIT.md is ${AUDIT_AGE_DAYS} days old. Consider running \`/audit\` to refresh."
            echo ""
        fi
    fi
fi

# Surface open knowledge debt — count entries matching the template format
# A real entry looks like: "## <Title> (noticed YYYY-MM-DD)"
# Template/system headers use other titles so we only match the dated pattern
if [[ -f "$DEBT_FILE" ]]; then
    # grep -c returns 1 when no matches, so we pipe through and default to 0
    DEBT_COUNT=$(grep -cE '^## .* \(noticed [0-9]{4}-[0-9]{2}-[0-9]{2}\)' "$DEBT_FILE" 2>/dev/null; true)
    DEBT_COUNT=${DEBT_COUNT:-0}
    if [[ "$DEBT_COUNT" -gt 0 ]] 2>/dev/null; then
        echo "### ⚠️ Open knowledge debt"
        echo "${DEBT_COUNT} unresolved entries in docs/knowledge-debt.md. Review before making related changes."
        echo ""
    fi
fi

exit 0
