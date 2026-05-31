#!/bin/bash
set -eo pipefail

shopt -s nullglob

PROFILE=$1
if [[ -z "$PROFILE" ]]; then
  echo "Usage: $0 <profile>" >&2
  exit 1
fi

REPO_DIR="repos/$PROFILE"
REPO_NAME="aur-$PROFILE"

# Clean obsolete local and remote package files not registered in the database
DELETED_LOCAL_PKGS=""

if [[ -f "$REPO_DIR/$REPO_NAME.db.tar.zst" ]]; then
  echo "=== [1/3] Extracting active packages from database ==="

  DESC_RAW=$(tar --wildcards -xOf "$REPO_DIR/$REPO_NAME.db.tar.zst" '*/desc')
  ACTIVE_PKGS=$(grep -A 1 '%FILENAME%' <<< "$DESC_RAW" | grep -v '%FILENAME%' | grep -v '^--$' || true)
  if [ -z "$ACTIVE_PKGS" ]; then
    echo 'No active packages, aborting.'
    exit 1
  fi

  echo "=== [2/3] Cleaning up obsolete local package files ==="
  for pkg_file in "$REPO_DIR"/*.pkg.tar.zst; do
    filename=$(basename "$pkg_file")
    if ! echo "$ACTIVE_PKGS" | grep -Fqx "$filename"; then
      echo "Deleting obsolete local package: $filename"
      DELETED_LOCAL_PKGS+="• ⚠️ <b>Obsolete file</b>: <code>$filename</code>"$'\n'
      rm -f "$pkg_file" "$pkg_file.sig"
    fi
  done

# Clean up obsolete remote release assets on GitHub that are no longer in the database
  echo "=== [3/3] Syncing GitHub Release assets with database ==="
  if ASSETS=$(gh release view "$PROFILE" --json assets --jq '.assets[].name' --repo "$GITHUB_REPOSITORY" 2>/dev/null); then
    while read -r asset || [[ -n "$asset" ]]; do
      [[ -n "$asset" ]] || continue
      if [[ "$asset" == *.pkg.tar.zst || "$asset" == *.pkg.tar.zst.sig ]]; then
        pkg_filename="${asset%.sig}"
        if ! echo "$ACTIVE_PKGS" | grep -Fqx "$pkg_filename"; then
          echo "Deleting obsolete Release asset: $asset"
          gh release delete-asset "$PROFILE" "$asset" -y --repo "$GITHUB_REPOSITORY" || true
        fi
      fi
    done <<< "$ASSETS"
  fi
else
  echo "=== No database found in $REPO_DIR. Skipping package and release asset cleanup. ==="
fi

# Resolve database symlinks
echo "=== Resolving pacman database symlinks ==="
for ext in db files; do
  if [[ -L "$REPO_DIR/$REPO_NAME.$ext" ]]; then
    echo "Converting symlink $REPO_NAME.$ext to actual file..."
    TARGET=$(readlink "$REPO_DIR/$REPO_NAME.$ext")
    rm "$REPO_DIR/$REPO_NAME.$ext"
    cp "$REPO_DIR/$TARGET" "$REPO_DIR/$REPO_NAME.$ext"
  fi
done

# Notify newly updated/built packages
UPDATED_FILES=( "$REPO_DIR"/*.pkg.tar.zst )
if [[ ${#UPDATED_FILES[@]} -gt 0 || -n "$DELETED_LOCAL_PKGS" || -f "$REPO_DIR/missing_packages.txt" ]]; then
  MSG_LIST=""

  if [[ ${#UPDATED_FILES[@]} -gt 0 ]]; then
    echo "=== Detecting built packages ==="

    # Load old package versions from the database backup
    declare -A OLD_VERSIONS
    OLD_DB_FILE="$REPO_DIR/$REPO_NAME.db.tar.zst.old"
    if [[ -f "$OLD_DB_FILE" ]]; then
      while read -r name version; do
        [[ -n "$name" && -n "$version" ]] && OLD_VERSIONS["$name"]="$version"
      done < <(tar --wildcards -xOf "$OLD_DB_FILE" '*/desc' | awk '
        /^%NAME%/ { get_name=1; next }
        /^%VERSION%/ { get_version=1; next }
        get_name { name=$1; get_name=0 }
        get_version { version=$1; get_version=0 }
        name && version { print name, version; name=""; version="" }
      ')
    fi

    # Load new versions and filenames from the new database
    declare -A FILENAME_TO_NAME
    declare -A NEW_VERSIONS
    if [[ -f "$REPO_DIR/$REPO_NAME.db.tar.zst" ]]; then
      while read -r name version filename; do
        if [[ -n "$name" && -n "$version" && -n "$filename" ]]; then
          FILENAME_TO_NAME["$filename"]="$name"
          NEW_VERSIONS["$name"]="$version"
        fi
      done < <(tar --wildcards -xOf "$REPO_DIR/$REPO_NAME.db.tar.zst" '*/desc' | awk '
        /^%NAME%/ { get_name=1; next }
        /^%VERSION%/ { get_version=1; next }
        /^%FILENAME%/ { get_file=1; next }
        get_name { name=$1; get_name=0 }
        get_version { version=$1; get_version=0 }
        get_file { file=$1; get_file=0 }
        name && version && file { print name, version, file; name=""; version=""; file="" }
      ')
    fi

    for f in "${UPDATED_FILES[@]}"; do
      filename=$(basename "$f")
      pkg_name="${FILENAME_TO_NAME["$filename"]}"

      # Heuristic fallback if not found in database metadata
      if [[ -z "$pkg_name" ]]; then
        pkg_name=$(echo "$filename" | sed -E 's/-[0-9].*//')
      fi

      new_ver="${NEW_VERSIONS["$pkg_name"]}"
      if [[ -z "$new_ver" ]]; then
        new_ver=$(echo "$filename" | sed -E 's/^[^-]+-//; s/-[^-]+.pkg.tar.zst$//')
      fi

      old_ver="${OLD_VERSIONS["$pkg_name"]}"
      if [[ -n "$old_ver" ]]; then
        MSG_LIST+="• $pkg_name: <code>$old_ver</code> → <code>$new_ver</code>"$'\n'
        echo "Detected updated package: $pkg_name ($old_ver -> $new_ver)"
      else
        MSG_LIST+="• $pkg_name: <code>$new_ver</code>"$'\n'
        echo "Detected new package: $pkg_name ($new_ver)"
      fi
    done
  fi

  # Load self-healed packages if any existed (Anomalies)
  MISSING_FILE="$REPO_DIR/missing_packages.txt"
  if [[ -f "$MISSING_FILE" ]]; then
    while read -r pkg_name || [[ -n "$pkg_name" ]]; do
      [[ -n "$pkg_name" ]] && MSG_LIST+="• ⚠️ <b>Missing</b>: $pkg_name"$'\n'
    done < "$MISSING_FILE"
    rm -f "$MISSING_FILE"
  fi

  if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    echo "Sending Telegram notification..."
    SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
    ACTION_URL="${SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    RELEASE_URL="${SERVER_URL}/${GITHUB_REPOSITORY}/releases/tag/${PROFILE}"

    TEXT="<b>auv #${PROFILE}</b> | <a href=\"${RELEASE_URL}\">Release</a> | <a href=\"${ACTION_URL}\">Action</a>

${MSG_LIST}${DELETED_LOCAL_PKGS}"

    curl -sSf -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "text=${TEXT}" \
      -d "parse_mode=HTML" \
      -d "disable_web_page_preview=true" > /dev/null || echo "Warning: Failed to send Telegram notification"
  else
    echo "Telegram credentials not set. Skipping notification."
  fi
fi

# Clean up database backups
for old_file in "$REPO_DIR"/*.old; do
  echo "Removing database backup: $(basename "$old_file")"
  rm "$old_file"
done
