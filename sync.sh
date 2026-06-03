#!/bin/bash
# sync.sh: Syncs and builds AUR packages for a profile directory.

set -eo pipefail

PROFILE_DIR=$1
if [[ -z $PROFILE_DIR || ! -d $PROFILE_DIR ]]; then
  echo "Usage: $0 <profile_directory>" >&2
  exit 1
fi

PROFILE_DIR=$(realpath "$PROFILE_DIR")

ARCH=$(basename "$PROFILE_DIR")
REPO_NAME="aur-$ARCH"
REPO_DIR="$PWD/repos/$ARCH"
CHROOT_DIR="$PWD/chroots/$ARCH"

PACKAGES_FILE="$PROFILE_DIR/packages.txt"
MAKEPKG_CONF="$PROFILE_DIR/makepkg.conf"

if [ ! -f "$PACKAGES_FILE" ]; then
  echo "[$ARCH] $PACKAGES_FILE not found, aborting." >&2
  exit 1
fi

PACMAN_CONF=$(mktemp --tmpdir "pacman-aur-$ARCH.XXXXXX")
MAKEPKG_TEMP_CONF=$(mktemp --tmpdir "makepkg-aur-$ARCH.XXXXXX")
BUILD_QUEUE=$(mktemp --tmpdir "aur-queue-$ARCH.XXXXXX")
trap 'rm -f "$PACMAN_CONF" "$MAKEPKG_TEMP_CONF" "$BUILD_QUEUE"' EXIT INT TERM

if [[ -f $MAKEPKG_CONF ]]; then
  cat /etc/makepkg.conf "$MAKEPKG_CONF" > "$MAKEPKG_TEMP_CONF"
else
  cat /etc/makepkg.conf > "$MAKEPKG_TEMP_CONF"
fi
echo 'OPTIONS+=(!debug)' >> "$MAKEPKG_TEMP_CONF"

# Parse package list file, ignoring comments and empty lines.
PACKAGES=()
mapfile -t PACKAGES < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$PACKAGES_FILE")

if (( ${#PACKAGES[@]} == 0 )); then
  echo "[$ARCH] No packages defined, aborting." >&2
  exit 1
fi

echo '=================================================='
echo "[$ARCH] Starting sync for profile: $ARCH"
echo "[$ARCH] Target repository: $REPO_NAME"
echo "[$ARCH] Packages: ${PACKAGES[*]}"
echo '=================================================='

# Ensure package database exists, preventing pacman from failing
mkdir -p "$REPO_DIR"
DB_FILE="$REPO_DIR/$REPO_NAME.db.tar.zst"
if [[ ! -f "$DB_FILE" ]]; then
  echo "[$ARCH] Pre-initializing empty database for $REPO_NAME..."
  if [[ -n $GPGKEY ]]; then
    repo-add -s -k "$GPGKEY" "$DB_FILE"
  else
    repo-add "$DB_FILE"
  fi
elif [[ ${#PACKAGES[@]} -gt 0 ]]; then
  # Reconcile database to drop obsolete packages (those deleted from packages.txt and their dependencies)
  "$(dirname $0)/auv.py" obsolete "$DB_FILE" "${PACKAGES[@]}"
fi

# Generate custom pacman.conf
cp /etc/pacman.conf "$PACMAN_CONF"

if [[ -n $GPGKEY ]]; then
  SIG_LEVEL='Required'
else
  SIG_LEVEL='Optional TrustAll'
fi

cat <<EOF >> "$PACMAN_CONF"

[$REPO_NAME]
SigLevel = $SIG_LEVEL
Server = file://$REPO_DIR
EOF

# Set AURDEST for clones
export AURDEST="$PWD/clones"
mkdir -p "$AURDEST"

# Common options shared by both aur sync and aur build
AUR_ARGS=(
  -d "$REPO_NAME"
  --pacman-conf "$PACMAN_CONF"
  --makepkg-conf "$MAKEPKG_TEMP_CONF"
  --noconfirm
  -C
)
[[ -n "$GPGKEY" ]] && AUR_ARGS+=( -S )
[[ -z $CI ]] && AUR_ARGS+=( -c -D "$CHROOT_DIR" )

# Find out which packages actually need to be updated/built
echo "[$ARCH] Syncing packages..."
aur sync --nobuild --noview "${AUR_ARGS[@]}" "${PACKAGES[@]}" > "$BUILD_QUEUE"

if [[ ! -s "$BUILD_QUEUE" ]]; then
  echo "[$ARCH] There is nothing to do."
  exit 0
fi

echo "[$ARCH] The following packages need to be built:"
cat "$BUILD_QUEUE"

# Apply custom patches/scripts to the newly fetched/updated packages
while read -r pkg_dir || [[ -n $pkg_dir ]]; do
  [[ -z $pkg_dir ]] && continue
  pkg=$(basename "$pkg_dir")

  if [[ -f "$PWD/patches/$pkg.patch" || -x "$PWD/patches/$pkg.sh" ]]; then
    git -C "$pkg_dir" reset --hard
    git -C "$pkg_dir" clean -df

    if [[ -f "$PWD/patches/$pkg.patch" ]]; then
      echo "[$ARCH] Applying custom patch for $pkg..."
      git -C "$pkg_dir" apply "$PWD/patches/$pkg.patch"
    elif [[ -x "$PWD/patches/$pkg.sh" ]]; then
      echo "[$ARCH] Executing custom patch script for $pkg..."
      "$PWD/patches/$pkg.sh" "$pkg_dir"
    fi
  fi
done < "$BUILD_QUEUE"

if [[ -n $GITHUB_REPOSITORY ]]; then
  echo "Server = https://github.com/$GITHUB_REPOSITORY/releases/download/$ARCH" >> "$PACMAN_CONF"
fi

# 3. Build Phase: Build the packages using aur build
echo "[$ARCH] Starting build for the packages in the queue..."
aur build "${AUR_ARGS[@]}" -s -a "$BUILD_QUEUE"
