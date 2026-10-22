#!/bin/bash
# sign.sh: Signs the unsigned packages and the database of a repository with $GPGKEY.

set -eo pipefail

shopt -s nullglob

if (( $# < 2 )); then
  echo "Usage: $0 <repo_dir> <repo_name>" >&2
  exit 1
fi

: "${GPGKEY:?GPGKEY must name the signing key}"

cd "$1"
REPO_NAME=$2

echo "Signing with GPG key $GPGKEY"

SIGNED=()
for pkg in *.pkg.tar.zst; do
  if [[ ! -f $pkg.sig ]]; then
    echo "Signing $pkg ..."
    gpg --batch --detach-sign --no-armor -u "$GPGKEY" "$pkg"
    SIGNED+=("$pkg")
  fi
done

# Embed the new package signatures in the database.
if (( ${#SIGNED[@]} > 0 )); then
  repo-add --include-sigs "$REPO_NAME.db.tar.zst" "${SIGNED[@]}"
fi

for db in "$REPO_NAME".{db,files}; do
  gpg --batch --yes --detach-sign --no-armor -u "$GPGKEY" "$db.tar.zst"
  ln -sf "$db.tar.zst.sig" "$db.sig"
done
