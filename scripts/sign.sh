#!/bin/bash
# Imports $GPG_PRIVATE_KEY into a temporary keyring and signs the repository with it.
set -eo pipefail

GNUPGHOME=$(mktemp -d)
export GNUPGHOME

if [[ $GPG_PRIVATE_KEY =~ 'BEGIN PGP PRIVATE KEY BLOCK' ]]; then
  gpg --batch --import <<< "$GPG_PRIVATE_KEY"
else
  base64 -d <<< "$GPG_PRIVATE_KEY" | gpg --batch --import
fi
unset GPG_PRIVATE_KEY

GPGKEY=${GPG_KEY_ID:-$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/ {print $5; exit}')}
export GPGKEY

exec "$(dirname "$0")/../sign.sh" "$@"
