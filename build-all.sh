#!/bin/bash
# build-all.sh: Sequentially build all discovered profile subdirectories.

set -eo pipefail

# Enable nullglob so unmatched wildcards expand to an empty list instead of the pattern literal
shopt -s nullglob

echo '=================================================='
echo '=== Starting AUR Build ==='
echo "=== Timestamp: $(date) ==="
echo '=================================================='

# Loop through all subdirectories in the profiles/ folder
for dir in "$PWD/profiles"/*/; do
  dir_name=$(basename "$dir")
  # If it contains a makepkg.conf, it is a profile!
  if [[ -f "$PWD/profiles/$dir_name/makepkg.conf" ]]; then
    ./sync.sh "$dir"
  fi
done

echo '=================================================='
echo '=== AUR Build Finished ==='
echo "=== Timestamp: $(date) ==="
echo '=================================================='
