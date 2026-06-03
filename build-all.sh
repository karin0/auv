#!/bin/bash
# build-all.sh: Sequentially build all discovered profile subdirectories.

set -eo pipefail

shopt -s nullglob

echo '=================================================='
echo '=== Starting AUR Build ==='
echo "=== Timestamp: $(date) ==="
echo '=================================================='

root="$(dirname $0)"

# Find and build all profiles
for dir in profiles/*/; do
  "$root/sync.sh" "$dir"
done

echo '=================================================='
echo '=== AUR Build Finished ==='
echo "=== Timestamp: $(date) ==="
echo '=================================================='
