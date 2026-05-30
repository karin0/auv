#!/bin/bash
set -eo pipefail

PROFILE=$1
if [[ -z "$PROFILE" ]]; then
  echo "Usage: $0 <profile>" >&2
  exit 1
fi

# If running as root, perform system setup and then re-execute this script as the builder user
if [[ "$EUID" -eq 0 ]]; then
  # A. Initialize the pacman keyring
  pacman-key --init
  pacman-key --populate archlinux

  # B. Install dependencies (expect is required by aurutils to prevent /dev/tty fallback errors)
  pacman -Syu --noconfirm base-devel expect

  # C. Disable pacman 7 landlock sandbox (unsupported on GitHub runners)
  sed -i 's,#DisableSandbox,DisableSandbox,' /etc/pacman.conf

  # D. Create unprivileged builder user matching host runner's UID/GID to avoid permission issues
  host_uid=$(stat -c '%u' /workspace)
  host_gid=$(stat -c '%g' /workspace)
  groupadd -g "$host_gid" builder || true
  useradd -m -u "$host_uid" -g builder builder || true
  echo 'builder ALL=(ALL:ALL) NOPASSWD: ALL' >> /etc/sudoers

  # E. Grant builder user ownership of workspace and pacman cache for compilation and caching
  chown -R builder:builder /workspace
  chown -R builder:builder /var/cache/pacman/pkg

  # F. Re-execute this exact script as the unprivileged builder user
  exec sudo -H -u builder env PATH="$PATH" "$0" "$@"
fi

# --- Beyond this point, the script runs entirely as the unprivileged builder user ---

# F. Download, compile, and install aurutils inside builder's home directory
cd ~
curl -sSfLO https://aur.archlinux.org/cgit/aur.git/snapshot/aurutils.tar.gz
tar -xf aurutils.tar.gz
cd aurutils
makepkg --syncdeps --noconfirm --skippgpcheck
sudo pacman -U --noconfirm aurutils-*.pkg.tar.zst

# Return to the mounted workspace directory
cd /workspace

# G. Self-healing: if a missing packages manifest was generated on the host, prune them from the database
MISSING_FILE="/workspace/repos/$PROFILE/missing_packages.txt"
DB_FILE="/workspace/repos/$PROFILE/aur-$PROFILE.db.tar.zst"
if [[ -f "$MISSING_FILE" ]]; then
  echo 'Self-healing: removing missing packages from database...'
  while read -r pkg_name || [[ -n "$pkg_name" ]]; do
    [[ -n "$pkg_name" ]] || continue
    echo "Removing $pkg_name from database to trigger rebuild..."
    repo-remove "$DB_FILE" "$pkg_name"
  done < "$MISSING_FILE"
  rm "$MISSING_FILE"
fi

# Prune any historical debug packages from the database as well
if [[ -f "$DB_FILE" ]]; then
  echo 'Self-healing: removing any historical debug packages from database...'
  DEBUG_PKGS=$(tar --wildcards -xOf "$DB_FILE" '*/desc' | awk '
    /^%NAME%/ { get_name=1; next }
    get_name { if ($1 ~ /-debug$/) print $1; get_name=0 }
  ' || true)

  if [[ -n "$DEBUG_PKGS" ]]; then
    echo "Found debug packages in database: $DEBUG_PKGS"
    for dpkg in $DEBUG_PKGS; do
      echo "Removing debug package '$dpkg' from database..."
      repo-remove "$DB_FILE" "$dpkg"
    done
  fi
fi

# H. Execute high-performance declarative sync script without chroot
NO_CHROOT=1 exec ./sync.sh "profiles/$PROFILE"
