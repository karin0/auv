#!/bin/bash
set -eo pipefail

sudo pacman -Syu --noconfirm

if [[ -n $GPG_PRIVATE_KEY ]]; then
  echo 'Configuring GnuPG for signing ...'
  mkdir -p ~/.gnupg
  chmod 700 ~/.gnupg
  echo 'pinentry-mode loopback' > ~/.gnupg/gpg.conf
  echo 'allow-loopback-pinentry' > ~/.gnupg/gpg-agent.conf
  gpgconf --kill gpg-agent || true

  echo 'Importing GPG private key...'
  if [[ $GPG_PRIVATE_KEY =~ 'BEGIN PGP PRIVATE KEY BLOCK' ]]; then
    echo "$GPG_PRIVATE_KEY" | gpg --batch --import
  else
    echo "$GPG_PRIVATE_KEY" | base64 -d | gpg --batch --import
  fi

  if [[ -z $GPG_KEY_ID ]]; then
    GPG_KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/ {print $5; exit}')
  fi
  export GPGKEY="$GPG_KEY_ID"
  unset GPG_PRIVATE_KEY GPG_KEY_ID
  echo "Using GPG key ID: $GPGKEY"

  gpg --export "$GPGKEY" | sudo pacman-key --add -
  sudo pacman-key --lsign-key "$GPGKEY"
  sudo pacman-key --finger "$GPGKEY"
fi

PYTHONUNBUFFERED=1 exec "$(dirname "$0")/build.py" "$@"
