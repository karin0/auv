#!/bin/bash
set -eo pipefail

shopt -s nullglob

PROFILE=$1
if [[ -z "$PROFILE" ]]; then
  echo "Usage: $0 <profile>" >&2
  exit 1
fi

REPO_DIR="repos/$PROFILE"
ACTIVE_FILE="state/$PROFILE/active-packages.txt"
NOTIFY_FILE="state/$PROFILE/notify-body.txt"

# Runs on the GitHub runner: no database parsing, only gh/Telegram and the file
# work the container left under state/<profile>/.

# Remove release assets no longer in the database. Guard on a non-empty active
# list so an empty/absent file never deletes everything.
if [[ -s "$ACTIVE_FILE" ]]; then
  echo "=== Removing obsolete release assets ==="
  if ASSETS=$(gh release view "$PROFILE" --json assets --jq '.assets[].name' --repo "$GITHUB_REPOSITORY" 2>/dev/null); then
    while read -r asset || [[ -n "$asset" ]]; do
      [[ -n "$asset" ]] || continue
      if [[ "$asset" == *.pkg.tar.zst || "$asset" == *.pkg.tar.zst.sig ]]; then
        if ! grep -Fqx "${asset%.sig}" "$ACTIVE_FILE"; then
          echo "Deleting obsolete Release asset: $asset"
          gh release delete-asset "$PROFILE" "$asset" -y --repo "$GITHUB_REPOSITORY" || true
        fi
      fi
    done <<< "$ASSETS"
  fi
else
  echo "=== Empty or missing active-package list. Skipping asset cleanup. ==="
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
if [[ -s "$NOTIFY_FILE" ]]; then
  if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    echo "Sending Telegram notification..."
    SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
    ACTION_URL="${SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    RELEASE_URL="${SERVER_URL}/${GITHUB_REPOSITORY}/releases/tag/${PROFILE}"

    TEXT="<b>auv #${PROFILE}</b> | <a href=\"${RELEASE_URL}\">Release</a> | <a href=\"${ACTION_URL}\">Action</a>

$(cat "$NOTIFY_FILE")"

    curl -sSf -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "text=${TEXT}" \
      -d "parse_mode=HTML" \
      -d "disable_web_page_preview=true" > /dev/null || echo "Warning: Failed to send Telegram notification"
  else
    echo "Telegram credentials not set. Skipping notification."
  fi
fi
