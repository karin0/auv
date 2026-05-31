#!/bin/bash
set -eo pipefail

PROFILE=$1
if [[ -z "$PROFILE" ]]; then
  echo "Usage: $0 <profile>" >&2
  exit 1
fi

# Set up system and re-execute as builder user if running as root
if [[ "$EUID" -eq 0 ]]; then
  pacman-key --init
  pacman-key --populate archlinux

  # Install dependencies (expect is required by aurutils to avoid tty issues)
  pacman -Syu --noconfirm base-devel expect

  # Disable pacman 7 sandbox (unsupported on GitHub runners)
  sed -i 's,#DisableSandbox,DisableSandbox,' /etc/pacman.conf

  # Create builder user matching host's UID/GID
  host_uid=$(stat -c '%u' /workspace)
  host_gid=$(stat -c '%g' /workspace)
  groupadd -g "$host_gid" builder || true
  useradd -m -u "$host_uid" -g builder builder || true
  echo 'builder ALL=(ALL:ALL) NOPASSWD: ALL' >> /etc/sudoers

  chown -R builder:builder /workspace
  chown -R builder:builder /var/cache/pacman/pkg

  exec sudo -H -u builder env PATH="$PATH" "$0" "$@"
fi

# --- Runs as builder user ---

# Install aurutils
cd ~
curl -sSfLO https://aur.archlinux.org/cgit/aur.git/snapshot/aurutils.tar.gz
tar -xf aurutils.tar.gz
cd aurutils
makepkg --syncdeps --noconfirm --skippgpcheck
sudo pacman -U --noconfirm aurutils-*.pkg.tar.zst

cd /workspace

# Remove missing packages from database to trigger rebuild
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

# Remove historical debug packages from database
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

# Run build
NO_CHROOT=1 ./sync.sh "profiles/$PROFILE"

# Rename packages containing colons to avoid GitHub and pacman 404 errors
echo "=== Checking for packages with colons in filenames ==="
shopt -s nullglob
REPO_DIR="/workspace/repos/$PROFILE"
for pkg_file in "$REPO_DIR"/*.pkg.tar.zst; do
  filename=$(basename "$pkg_file")
  if [[ "$filename" == *:* ]]; then
    new_filename=$(echo "$filename" | sed 's/:/-colon-/g')
    new_pkg_file="$REPO_DIR/$new_filename"
    
    echo "Renaming $filename to $new_filename in database..."
    
    # Extract package name from filename using pacman inside the container
    pkg_name=$(pacman -Qp "$pkg_file" | awk '{print $1}')
    
    # Remove the old entry with the colon from the database
    repo-remove "$DB_FILE" "$pkg_name"
    
    # Move the physical file to the new name without colons
    mv "$pkg_file" "$new_pkg_file"
    
    # Also rename the signature file if it exists
    if [[ -f "$pkg_file.sig" ]]; then
      mv "$pkg_file.sig" "$new_pkg_file.sig"
    fi
    
    # Add the renamed package back to the database
    repo-add "$DB_FILE" "$new_pkg_file"
  fi
done
