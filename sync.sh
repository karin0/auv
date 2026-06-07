#!/bin/bash
# sync.sh: Syncs and builds AUR packages for a repository.

set -eo pipefail

if (( $# < 3 )); then
  echo "Usage: $0 <profile> <repo_name> <packages_file>" >&2
  exit 1
fi

PROFILE=$1
REPO_NAME=$2
PACKAGES_FILE=$3

REPO_DIR="$PWD/repos/$PROFILE"
CHROOT_DIR="$PWD/chroots/$PROFILE"

PACMAN_CONF=$(mktemp --tmpdir "pacman-$PROFILE.XXXXXX")
MAKEPKG_TEMP_CONF=$(mktemp --tmpdir "makepkg-$PROFILE.XXXXXX")
BUILD_QUEUE=$(mktemp --tmpdir "aur-queue-$PROFILE.XXXXXX")
PACMAN_WRAPPER=$(mktemp --tmpdir "pacman-wrapper-$PROFILE.XXXXXX")
trap 'rm -f "$PACMAN_CONF" "$MAKEPKG_TEMP_CONF" "$BUILD_QUEUE" "$PACMAN_WRAPPER"' EXIT INT TERM

if [[ -n $AUV_MAKEPKG_CONF_FILE ]]; then
  cat /etc/makepkg.conf "$AUV_MAKEPKG_CONF_FILE" > "$MAKEPKG_TEMP_CONF"
else
  cat /etc/makepkg.conf > "$MAKEPKG_TEMP_CONF"
fi
echo 'OPTIONS+=(!debug)' >> "$MAKEPKG_TEMP_CONF"

# Parse package list file, ignoring comments and empty lines.
PACKAGES=()
mapfile -t PACKAGES < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$PACKAGES_FILE")

if (( ${#PACKAGES[@]} == 0 )); then
  echo "[$PROFILE] No packages defined, aborting." >&2
  exit 1
fi

echo '=================================================='
echo "[$PROFILE] Starting sync for repository: $REPO_NAME"
echo "[$PROFILE] Packages: ${PACKAGES[*]}"
echo '=================================================='

# Ensure package database exists, preventing pacman from failing
mkdir -p "$REPO_DIR"
DB_FILE="$REPO_DIR/$REPO_NAME.db.tar.zst"
if [[ ! -f "$DB_FILE" ]]; then
  echo "[$PROFILE] Pre-initializing empty database for $REPO_NAME..."
  if [[ -n $GPGKEY ]]; then
    repo-add -s -k "$GPGKEY" "$DB_FILE"
  else
    repo-add "$DB_FILE"
  fi
else
  # Reconcile database to drop obsolete packages (those deleted from packages file and their dependencies)
  "$(dirname "$0")/auv.py" obsolete "$DB_FILE" "${PACKAGES[@]}"
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

if [[ -n $GITHUB_REPOSITORY ]]; then
  echo "[$PROFILE] Adding release repo from $GITHUB_REPOSITORY"
  echo "Server = https://github.com/$GITHUB_REPOSITORY/releases/download/$PROFILE" >> "$PACMAN_CONF"
fi

sudo pacman --config "$PACMAN_CONF" -Syu --noconfirm || true

# Ensure `makepkg -s` uses the custom pacman.conf
cat <<EOF > "$PACMAN_WRAPPER"
#!/bin/bash
echo "> \$0 \$*" >&2
exec pacman --config '$PACMAN_CONF' "\$@"
EOF
chmod +x "$PACMAN_WRAPPER"
export PACMAN="$PACMAN_WRAPPER"

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
echo "[$PROFILE] Syncing packages with ${AUR_ARGS[*]} ..."
aur sync --nobuild --noview "${AUR_ARGS[@]}" "${PACKAGES[@]}" > "$BUILD_QUEUE"

if [[ ! -s "$BUILD_QUEUE" ]]; then
  echo "[$PROFILE] There is nothing to do."
  exit 0
fi

echo "[$PROFILE] The following packages need to be built:"
cat "$BUILD_QUEUE"

# Apply custom patches/scripts to the newly fetched/updated packages
PATCHES_DIR="$AUV_PATCHES_DIR"
if [[ -n $PATCHES_DIR && -d $PATCHES_DIR ]]; then
  echo "[$PROFILE] Applying custom patches from $PATCHES_DIR..."
  while read -r pkg_dir || [[ -n $pkg_dir ]]; do
    [[ -z $pkg_dir ]] && continue
    pkg=$(basename "$pkg_dir")

    if [[ ( -f "$PATCHES_DIR/$pkg.patch" || -x "$PATCHES_DIR/$pkg.sh" ) ]]; then
      git -C "$pkg_dir" reset --hard
      git -C "$pkg_dir" clean -df

      if [[ -f "$PATCHES_DIR/$pkg.patch" ]]; then
        echo "[$PROFILE] Applying custom patch for $pkg..."
        git -C "$pkg_dir" apply "$PATCHES_DIR/$pkg.patch"
      elif [[ -x "$PATCHES_DIR/$pkg.sh" ]]; then
        echo "[$PROFILE] Executing custom patch script for $pkg..."
        "$PATCHES_DIR/$pkg.sh" "$pkg_dir"
      fi
    fi
  done < "$BUILD_QUEUE"
fi

echo "[$PROFILE] Starting build for the packages in the queue..."
aur build "${AUR_ARGS[@]}" -s -a "$BUILD_QUEUE"
