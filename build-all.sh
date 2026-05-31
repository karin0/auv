#!/bin/bash
# build-all.sh: Sequentially build all discovered profile subdirectories.

set -eo pipefail

shopt -s nullglob

echo '=================================================='
echo '=== Starting AUR Build ==='
echo "=== Timestamp: $(date) ==="
echo '=================================================='

# Find and build all profiles
for dir in "$PWD/profiles"/*/; do
  dir_name=$(basename "$dir")
  if [[ -f "$PWD/profiles/$dir_name/makepkg.conf" ]]; then
    ./sync.sh "$dir"
  fi
done

echo '=================================================='
echo '=== AUR Build Finished ==='
echo "=== Timestamp: $(date) ==="
echo '=================================================='
