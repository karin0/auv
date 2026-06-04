#!/bin/bash
# This script is failable, so safety of later steps must not rely on our side effects.
set -eo pipefail

PROFILE=$1

if [[ -z $PROFILE ]]; then
  echo "Usage: $0 <release_tag>" >&2
  exit 1
fi

REPO_DIR="repos/$PROFILE"
STATE_DIR="state/$PROFILE"
ASSETS_FILE="$STATE_DIR/release-assets.txt"

rm -rf "$REPO_DIR" "$STATE_DIR"
mkdir -p "$REPO_DIR" "$STATE_DIR"

# Snapshot release assets for the container to reconcile against.
# Fail-fast if the release doesn't exist.
echo '== Snapshotting current release assets ==='

# For later steps, we must ensure the ASSETS_FILE exists iff the release exists.
gh release view "$PROFILE" --json assets --jq '.assets[].name' --repo "$GITHUB_REPOSITORY" > "$ASSETS_FILE".1
mv "$ASSETS_FILE".1 "$ASSETS_FILE"
echo "Recorded $(grep -c . "$ASSETS_FILE") release assets:"
cat "$ASSETS_FILE"

echo "=== Downloading Pacman database from release '$PROFILE' ==="
gh release download "$PROFILE" \
  -D "$REPO_DIR" \
  -p "*.db.tar.zst*" \
  -p "*.files.tar.zst*" \
  -R "$GITHUB_REPOSITORY"

# Recreate database symlinks so repo-add and aurutils operate correctly.
echo '=== Recovering database symlinks ==='
cd "$REPO_DIR"
for dst in *.tar.zst*; do
  src="${dst//.tar.zst/}"
  echo "Recreating symlink for $src -> $dst ..."
  ln -s "$dst" "$src"
done
