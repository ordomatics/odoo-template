#!/usr/bin/env bash
# ==============================================================================
# scripts/setup-submodules.sh
# Initialize submodules and apply sparse-checkout patterns declared in
# .gitmodules via the custom `sparseCheckout` key.
#
# Adding a new submodule with sparse checkout:
#   1. git submodule add <url> addons/<path>
#   2. Add `sparseCheckout = <pattern> [<pattern> ...]` to its .gitmodules entry
#   3. Re-run this script — nothing else needs to change.
#
# Submodules without a sparseCheckout key are checked out in full.
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

echo "=== Initializing submodules ==="
git submodule update --init --recursive

echo "=== Applying sparse-checkout patterns from .gitmodules ==="

# Use process substitution instead of pipe so the while loop runs in the
# current shell — this lets set -e catch failures inside the loop correctly.
# git config lowercases all key names, so sparseCheckout → sparsecheckout;
# strip the suffix with %.*  (last dot-segment) to handle any casing.
while IFS=' ' read -r key patterns; do
    # key = submodule.<name>.sparsecheckout  →  extract <name>
    name="${key#submodule.}"
    name="${name%.*}"
    path=$(git config -f .gitmodules "submodule.${name}.path")

    echo "  sparse: ${path} → ${patterns}"
    git -C "${path}" config core.sparseCheckout true
    mkdir -p ".git/modules/${path}/info"
    # Write each space-separated pattern on its own line
    echo "${patterns}" | tr ' ' '\n' > ".git/modules/${path}/info/sparse-checkout"
    git submodule update --force "${path}"
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.sparsecheckout$')

echo "=== Done ==="
