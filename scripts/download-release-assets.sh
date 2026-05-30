#!/bin/bash
set -eo pipefail

PROFILE=$1
if [[ -z "$PROFILE" ]]; then
  echo "Usage: $0 <profile>" >&2
  exit 1
fi

REPO_DIR="repos/$PROFILE"
REPO_NAME="aur-$PROFILE"
mkdir -p "$REPO_DIR"

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

# B. Verify database integrity against remote Release assets to recover any missing packages
DB_FILE="$REPO_DIR/$REPO_NAME.db.tar.zst"
MISSING_FILE="$REPO_DIR/missing_packages.txt"
rm -f "$MISSING_FILE"

if [[ -f "$DB_FILE" ]]; then
  echo "=== Checking database integrity against remote Release assets ==="
  if ASSETS=$(gh release view "$PROFILE" --json assets --jq '.assets[].name' --repo "$GITHUB_REPOSITORY" 2>/dev/null); then
    # Extract package names and filenames from the database desc files
    tar --wildcards -xOf "$DB_FILE" '*/desc' | awk '
      /^%NAME%/ { get_name=1; next }
      /^%FILENAME%/ { get_file=1; next }
      get_name { name=$1; get_name=0 }
      get_file { file=$1; get_file=0 }
      name && file { print name, file; name=""; file="" }
    ' | while read -r pkg_name pkg_file; do
      if ! echo "$ASSETS" | grep -Fqx "$pkg_file"; then
        echo "Package file $pkg_file is missing from Release. Marking $pkg_name for self-healing..."
        echo "$pkg_name" >> "$MISSING_FILE"
      fi
    done
  fi
fi
