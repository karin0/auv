#!/bin/bash
set -eo pipefail

# Enable nullglob so unmatched wildcards expand to an empty list instead of the pattern literal
shopt -s nullglob

PROFILE=$1
if [[ -z "$PROFILE" ]]; then
  echo "Usage: $0 <profile>" >&2
  exit 1
fi

REPO_DIR="repos/$PROFILE"
REPO_NAME="aur-$PROFILE"

# A. Clean up obsolete local and remote package files not registered in the database
if [[ -f "$REPO_DIR/$REPO_NAME.db.tar.zst" ]]; then
  echo "=== [1/3] Extracting active packages from database ==="
  ACTIVE_PKGS=$(tar --wildcards -xOf "$REPO_DIR/$REPO_NAME.db.tar.zst" '*/desc' | grep -A 1 '%FILENAME%' | grep -v '%FILENAME%' | grep -v '^--$' || true)

  echo "=== [2/3] Cleaning up obsolete local package files ==="
  for pkg_file in "$REPO_DIR"/*.pkg.tar.zst; do
    filename=$(basename "$pkg_file")
    if ! echo "$ACTIVE_PKGS" | grep -Fqx "$filename"; then
      echo "Deleting obsolete local package: $filename"
      rm "$pkg_file"
    fi
  done

  # Clean up obsolete remote release assets on GitHub that are no longer active in the database
  echo "=== [3/3] Syncing GitHub Release assets with database ==="
  if ASSETS=$(gh release view "$PROFILE" --json assets --jq '.assets[].name' --repo "$GITHUB_REPOSITORY" 2>/dev/null); then
    echo "$ASSETS" | while read -r asset; do
      [[ -n "$asset" ]] || continue
      # Only delete package assets (.pkg.tar.zst or .pkg.tar.zst.sig) that are not in the active database list
      if [[ "$asset" == *.pkg.tar.zst || "$asset" == *.pkg.tar.zst.sig ]]; then
        pkg_filename="${asset%.sig}"
        if ! echo "$ACTIVE_PKGS" | grep -Fqx "$pkg_filename"; then
          echo "Deleting obsolete Release asset: $asset"
          gh release delete-asset "$PROFILE" "$asset" -y --repo "$GITHUB_REPOSITORY" || true
        fi
      fi
    done
  fi
else
  echo "=== No database found in $REPO_DIR. Skipping package and release asset cleanup. ==="
fi

# B. Resolve symlinks and clean temporary backups
echo "=== Resolving pacman database symlinks and cleaning backups ==="
# Remove temporary .old database backups created by repo-add
for old_file in "$REPO_DIR"/*.old; do
  echo "Removing temporary database backup: $(basename "$old_file")"
  rm "$old_file"
done

for ext in db files; do
  if [[ -L "$REPO_DIR/$REPO_NAME.$ext" ]]; then
    echo "Converting symlink $REPO_NAME.$ext to actual file..."
    TARGET=$(readlink "$REPO_DIR/$REPO_NAME.$ext")
    rm "$REPO_DIR/$REPO_NAME.$ext"
    cp "$REPO_DIR/$TARGET" "$REPO_DIR/$REPO_NAME.$ext"
  fi
done
