#!/bin/bash
set -eo pipefail

shopt -s nullglob

PROFILE=$1
if [[ -z "$PROFILE" ]]; then
  echo "Usage: $0 <profile>" >&2
  exit 1
fi

# Set up system and re-execute as builder user if running as root
if [[ "$EUID" -eq 0 ]]; then
  pacman-key --init
  pacman-key --populate archlinux

  # expect is required by aurutils, pacman-contrib for paccache, pyalpm
  # for repo-list
  pacman -Syu --noconfirm base-devel expect pacman-contrib pyalpm

  # Create builder user matching host's UID/GID; alpm group lets pacman's
  # download user reach the files it generates
  host_uid=$(stat -c '%u' /workspace)
  host_gid=$(stat -c '%g' /workspace)
  groupadd -g "$host_gid" builder
  useradd -m -u "$host_uid" -g builder -G alpm builder
  echo 'builder ALL=(ALL:ALL) NOPASSWD: ALL' >> /etc/sudoers

  chown -R builder:builder /workspace
  chown -R builder:builder /var/cache/pacman/pkg

  # Put repo-list and friends on PATH for the builder run
  exec sudo -H -u builder env PATH="/workspace/scripts:$PATH" "$0" "$@"
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

# This is the only place that parses the pacman database (where pyalpm and the
# pacman tools live). The runner-side scripts hand it inputs and read its outputs
# via files under state/<profile>/.
REPO_DIR="/workspace/repos/$PROFILE"
DB_FILE="$REPO_DIR/aur-$PROFILE.db.tar.zst"
OLD_DB_FILE="$DB_FILE.old"
STATE_DIR="/workspace/state/$PROFILE"
RELEASE_ASSETS="$STATE_DIR/release-assets.txt"
ACTIVE_FILE="$STATE_DIR/active-packages.txt"
NOTIFY_FILE="$STATE_DIR/notify-body.txt"
mkdir -p "$STATE_DIR"

NOTIFY_MISSING=""
NOTIFY_UPDATED=""
NOTIFY_OBSOLETE=""

# Force a rebuild of any package whose file is missing from the release. The
# release-assets file is absent when no release exists yet, so skip then.
if [[ -f "$DB_FILE" && -f "$RELEASE_ASSETS" ]]; then
  echo 'Reconciling database against release assets...'
  while IFS=$'\t' read -r pkg_name pkg_file; do
    [[ -n "$pkg_name" ]] || continue
    if ! grep -Fqx "$pkg_file" "$RELEASE_ASSETS"; then
      echo "Asset $pkg_file missing; removing $pkg_name to trigger rebuild..."
      repo-remove "$DB_FILE" "$pkg_name"
      NOTIFY_MISSING+="• ⚠️ <b>Missing</b>: $pkg_name"$'\n'
    fi
  done < <(repo-list "$DB_FILE" name filename)
fi

# Drop historical debug packages from the database
if [[ -f "$DB_FILE" ]]; then
  while IFS= read -r pkg_name; do
    [[ "$pkg_name" == *-debug ]] || continue
    echo "Removing debug package '$pkg_name' from database..."
    repo-remove "$DB_FILE" "$pkg_name"
  done < <(repo-list "$DB_FILE" name)
fi

# Run build
NO_CHROOT=1 ./sync.sh "profiles/$PROFILE"

# Rename packages containing colons to avoid GitHub and pacman 404 errors
echo "=== Checking for packages with colons in filenames ==="
for pkg_file in "$REPO_DIR"/*.pkg.tar.zst; do
  filename=$(basename "$pkg_file")
  if [[ "$filename" == *:* ]]; then
    new_filename="${filename//:/-colon-}"
    new_pkg_file="$REPO_DIR/$new_filename"
    echo "Renaming $filename to $new_filename in database..."

    pkg_name=$(pacman -Qp "$pkg_file" | awk '{print $1}')
    repo-remove "$DB_FILE" "$pkg_name"
    mv "$pkg_file" "$new_pkg_file"
    [[ -f "$pkg_file.sig" ]] && mv "$pkg_file.sig" "$new_pkg_file.sig"
    repo-add "$DB_FILE" "$new_pkg_file"
  fi
done

# Keep only the latest cached version of each package
echo "=== Cleaning up Pacman cache ==="
sudo paccache -rk1

# Drop AUR clones not registered in the database
AURDEST="/workspace/clones"
if [[ -d "$AURDEST" && -f "$DB_FILE" ]]; then
  echo "=== Cleaning up obsolete AUR clones ==="
  declare -A keep_clones
  while IFS= read -r pkg_name; do
    [[ -n "$pkg_name" ]] && keep_clones["$pkg_name"]=1
  done < <(repo-list "$DB_FILE" name)

  for clone_dir in "$AURDEST"/*/; do
    clone_name=$(basename "$clone_dir")
    if [[ -z "${keep_clones["$clone_name"]}" ]]; then
      echo "Removing obsolete AUR clone: $clone_name"
      rm -rf "$clone_dir"
    fi
  done
fi

# Hand the runner the active package list and the database-derived notification
# lines. Only freshly built packages have their .pkg file present (the database
# alone was downloaded to start with), so the glob below is exactly this run's
# output.
if [[ -f "$DB_FILE" ]]; then
  repo-list "$DB_FILE" filename > "$ACTIVE_FILE"

  # Drop local package files no longer in the database
  echo "=== Removing obsolete local package files ==="
  for pkg_file in "$REPO_DIR"/*.pkg.tar.zst; do
    filename=$(basename "$pkg_file")
    if ! grep -Fqx "$filename" "$ACTIVE_FILE"; then
      echo "Deleting obsolete local package: $filename"
      NOTIFY_OBSOLETE+="• ⚠️ <b>Obsolete file</b>: <code>$filename</code>"$'\n'
      rm -f "$pkg_file" "$pkg_file.sig"
    fi
  done

  echo "=== Detecting built packages ==="
  declare -A OLD_VERSIONS
  if [[ -f "$OLD_DB_FILE" ]]; then
    while IFS=$'\t' read -r name version; do
      [[ -n "$name" ]] && OLD_VERSIONS["$name"]="$version"
    done < <(repo-list "$OLD_DB_FILE" name version)
  fi

  for pkg_file in "$REPO_DIR"/*.pkg.tar.zst; do
    read -r pkg_name new_ver < <(pacman -Qp "$pkg_file")
    old_ver="${OLD_VERSIONS["$pkg_name"]}"
    if [[ -n "$old_ver" ]]; then
      NOTIFY_UPDATED+="• $pkg_name: <code>$old_ver</code> → <code>$new_ver</code>"$'\n'
      echo "Updated: $pkg_name ($old_ver -> $new_ver)"
    else
      NOTIFY_UPDATED+="• $pkg_name: <code>$new_ver</code>"$'\n'
      echo "New: $pkg_name ($new_ver)"
    fi
  done
fi

printf '%s' "${NOTIFY_UPDATED}${NOTIFY_MISSING}${NOTIFY_OBSOLETE}" > "$NOTIFY_FILE"
