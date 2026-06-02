#!/bin/bash
# This script is failable, so safety of later steps must not rely on our side effects.
set -eo pipefail

PROFILE=$1
if [[ -z "$PROFILE" ]]; then
  echo "Usage: $0 <profile>" >&2
  exit 1
fi

REPO_DIR="repos/$PROFILE"
REPO_NAME="aur-$PROFILE"
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

echo "=== Downloading Pacman database for profile '$PROFILE' ==="
gh release download "$PROFILE" \
  --dir "$REPO_DIR" \
  --pattern "$REPO_NAME.db*" \
  --pattern "$REPO_NAME.files*" \
  --repo "$GITHUB_REPOSITORY"

# Recreate database symlinks so repo-add and aurutils operate correctly.
echo '=== Recovering database symlinks ==='
for ext in db files; do
  src="$REPO_DIR/$REPO_NAME.$ext"
  dst="$REPO_NAME.$ext.tar.zst"
  if [[ -f $src && ! -L $src && -f "$REPO_DIR/$dst" ]]; then
    echo "Recreating symlink for $src -> $dst ..."
    ln -sf "$dst" "$src"
  fi
done
