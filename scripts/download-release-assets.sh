#!/bin/bash
set -eo pipefail

PROFILE=$1
if [[ -z "$PROFILE" ]]; then
  echo "Usage: $0 <profile>" >&2
  exit 1
fi

REPO_DIR="repos/$PROFILE"
REPO_NAME="aur-$PROFILE"
STATE_DIR="state/$PROFILE"
mkdir -p "$REPO_DIR" "$STATE_DIR"

# Runs on the GitHub runner: only network/gh work. Database parsing happens in
# the Arch container, fed via files under state/<profile>/.

echo "=== Downloading Pacman database for profile '$PROFILE' ==="
gh release download "$PROFILE" \
  --dir "$REPO_DIR" \
  --pattern "$REPO_NAME.db*" \
  --pattern "$REPO_NAME.files*" \
  --repo "$GITHUB_REPOSITORY" || true

# Recreate database symlinks so repo-add and aurutils operate correctly
for ext in db files; do
  if [[ -f "$REPO_DIR/$REPO_NAME.$ext" && ! -L "$REPO_DIR/$REPO_NAME.$ext" ]]; then
    echo "Recreating symlink for $REPO_NAME.$ext..."
    rm "$REPO_DIR/$REPO_NAME.$ext"
    ln -s "$REPO_NAME.$ext.tar.zst" "$REPO_DIR/$REPO_NAME.$ext"
  fi
done

# Snapshot release assets for the container to reconcile against. Written only
# when the release exists; its absence tells the container to skip the check.
echo "=== Snapshotting current release assets ==="
ASSETS_FILE="$STATE_DIR/release-assets.txt"
rm -f "$ASSETS_FILE"
if ASSETS=$(gh release view "$PROFILE" --json assets --jq '.assets[].name' --repo "$GITHUB_REPOSITORY" 2>/dev/null); then
  printf '%s\n' "$ASSETS" > "$ASSETS_FILE"
  echo "Recorded $(grep -c . "$ASSETS_FILE" || true) release assets."
else
  echo "No release found for '$PROFILE'; integrity check will be skipped."
fi
