#!/bin/bash
# build-all.sh: Sequentially build all discovered profile subdirectories.

set -eo pipefail

shopt -s nullglob

echo '=================================================='
echo '=== Starting AUR Build ==='
echo "=== Timestamp: $(date) ==="
echo '=================================================='

root="$(dirname "$0")"
if [ -d patches ]; then
  export AUV_PATCHES_DIR=patches
fi

# Find and build all profiles
for dir in profiles/*/; do
  profile=$(basename "$dir")
  if [[ -f "${dir}makepkg.conf" ]]; then
    export AUV_MAKEPKG_CONF_FILE="${dir}makepkg.conf"
  else
    unset AUV_MAKEPKG_CONF_FILE
  fi
  "$root/sync.sh" "$profile" "aur-$profile" "${dir}packages.txt"
done

echo '=================================================='
echo '=== AUR Build Finished ==='
echo "=== Timestamp: $(date) ==="
echo '=================================================='
