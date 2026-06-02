#!/bin/bash
set -eo pipefail

shopt -s nullglob

PROFILE=$1
if [[ -z $PROFILE ]]; then
  echo "Usage: $0 <profile>" >&2
  exit 1
fi

REPO_DIR="repos/$PROFILE"
ASSETS_FILE="state/$PROFILE/release-assets.txt"
OBSOLETE_FILE="state/$PROFILE/obsolete-assets.txt"
NOTIFY_FILE="state/$PROFILE/notify.txt"

[[ -s $NOTIFY_FILE ]]

# Remove release assets no longer in the database.
if [[ -s $OBSOLETE_FILE ]]; then
  echo "=== Removing obsolete release assets ==="
  while read -r asset || [[ -n $asset ]]; do
    [[ -z $asset ]] && continue
    echo "Deleting obsolete asset: $asset"
    gh release delete-asset "$PROFILE" "$asset" -y --repo "$GITHUB_REPOSITORY" || true
  done < "$OBSOLETE_FILE"
else
  echo "=== No obsolete release assets. ==="
fi

cd "$REPO_DIR"

# Remove database backups so they aren't uploaded as assets
rm -f -- *.old

# Resolve database symlinks (symlinks fail to upload as release assets)
for file in *; do
  if [[ -L $file ]]; then
    target=$(readlink "$file")
    echo "Converting symlink $file to target $target ..."
    rm "$file"
    cp "$target" "$file"
  fi
done

cd -

# Notify with the body the container assembled, prefixed by the run-context header
if [[ -n $TELEGRAM_BOT_TOKEN && -n $TELEGRAM_CHAT_ID ]]; then
  echo "Sending Telegram notification..."
  SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
  ACTION_URL="$SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  RELEASE_URL="$SERVER_URL/$GITHUB_REPOSITORY/releases/tag/$PROFILE"

  TEXT="<b>auv #$PROFILE</b> | <a href=\"$RELEASE_URL\">Release</a> | <a href=\"$ACTION_URL\">Action</a>

$(cat "$NOTIFY_FILE")"

  curl -sSf -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d "chat_id=$TELEGRAM_CHAT_ID" \
    -d "text=$TEXT" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" > /dev/null || echo "Failed to send Telegram notification"
else
  echo "Telegram credentials not set. Skipping notification:"
  cat "$NOTIFY_FILE"
fi

echo "=== Uploading and Clobbering Assets to Release Channel ==="
if [[ ! -f $ASSETS_FILE ]]; then
  echo "Creating new release for $PROFILE first ..."
  gh release create "$PROFILE" --title "$PROFILE" --repo "$GITHUB_REPOSITORY"
fi

exec gh release upload "$PROFILE" "$REPO_DIR"/* --clobber --repo "$GITHUB_REPOSITORY"
