#!/bin/bash
set -euo pipefail

if ! command -v bd &> /dev/null; then
    echo "ERROR: bd command not found"
    exit 1
fi

installed_output=$(bd version)
installed_commit=$(printf '%s\n' "$installed_output" | grep -oE '[0-9a-f]{8,40}' | head -1 || true)
upstream_commit=$(git ls-remote https://github.com/gastownhall/beads.git refs/heads/main | cut -f1)

echo "Installed beads: $installed_output"
echo "Installed commit: ${installed_commit:-unknown}"
echo "Upstream main:    $upstream_commit"

if [[ -n "$installed_commit" && "$upstream_commit" == "$installed_commit"* ]]; then
    echo "OK: Installed bd matches upstream main"
else
    echo "WARNING: Installed bd does not match the latest upstream main commit."
    echo "Run .agents/setup to update it, then test compatibility."
    exit 1
fi
