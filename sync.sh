#!/bin/bash
# sync.sh: Syncs and builds AUR packages for a profile directory.
# shellcheck disable=SC2218

set -eo pipefail

# Parse package list file recursively, handling comments, empty lines, and 'include'.
parse_list() {
  local list_file=$1
  [[ -f "$list_file" ]] || return 0

  local file_dir
  file_dir=$(dirname "$list_file")

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Trim leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # Ignore empty lines and comments
    if [[ -z "$line" || "$line" == "#"* ]]; then
      continue
    fi

    # Check if the line is an include directive: "include <path>"
    if [[ "$line" =~ ^include[[:space:]]+(.+)$ ]]; then
      local include_target="${BASH_REMATCH[1]}"
      # If the target is not an absolute path, resolve it relative to the current file's directory
      if [[ "$include_target" != /* ]]; then
        include_target="$file_dir/$include_target"
      fi
      parse_list "$include_target"
    else
      echo "$line"
    fi
  done < "$list_file"
}

PROFILE_DIR=$1
if [[ -z "$PROFILE_DIR" || ! -d "$PROFILE_DIR" ]]; then
  echo "Usage: $0 <profile_directory>" >&2
  exit 1
fi

PROFILE_DIR=$(realpath "$PROFILE_DIR")

ARCH=$(basename "$PROFILE_DIR")
REPO_NAME="aur-$ARCH"
REPO_DIR="$PWD/repos/$ARCH"
CHROOT_DIR="$PWD/chroots/$ARCH"
MAKEPKG_CONF="$PROFILE_DIR/makepkg.conf"

if [[ ! -f "$MAKEPKG_CONF" ]]; then
  echo 'Error: Profile directory must contain makepkg.conf' >&2
  exit 1
fi

PACMAN_CONF=$(mktemp --tmpdir "pacman-aur-$ARCH.XXXXXX")
MAKEPKG_TEMP_CONF=$(mktemp --tmpdir "makepkg-aur-$ARCH.XXXXXX")

# Merge defaults with profile overrides
cat /etc/makepkg.conf "$MAKEPKG_CONF" > "$MAKEPKG_TEMP_CONF"
echo 'OPTIONS+=(!debug)' >> "$MAKEPKG_TEMP_CONF"

# Parse packages
PACKAGES=()
mapfile -t PACKAGES < <(parse_list "$PROFILE_DIR/packages.txt")

# Deduplicate packages
mapfile -t PACKAGES < <(printf '%s\n' "${PACKAGES[@]}" | sort -u)

if (( ${#PACKAGES[@]} == 0 )); then
  echo "[$ARCH] No packages defined for this profile. Skipping."
  exit 0
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
  repo-add "$DB_FILE"
fi

# Generate custom pacman.conf
cp /etc/pacman.conf "$PACMAN_CONF"
cat <<EOF >> "$PACMAN_CONF"

[$REPO_NAME]
SigLevel = Optional TrustAll
Server = file://$REPO_DIR
EOF

if [[ -n "$GITHUB_REPOSITORY" ]]; then
  echo "Server = https://github.com/${GITHUB_REPOSITORY}/releases/download/$ARCH" >> "$PACMAN_CONF"
fi

# Fetch and patch packages
export AURDEST="$PWD/clones"
mkdir -p "$AURDEST"
for pkg in "${PACKAGES[@]}"; do
  if [[ -f "$PWD/patches/$pkg.patch" || -x "$PWD/patches/$pkg.sh" ]]; then
    echo "[$ARCH] Custom patch/script detected for $pkg. Pre-fetching..."
    ( cd "$AURDEST" && aur fetch "$pkg" )

    # Reset clone to clean state
    git -C "$AURDEST/$pkg" reset --hard >/dev/null 2>&1 || true
    git -C "$AURDEST/$pkg" clean -df >/dev/null 2>&1 || true

    if [[ -f "$PWD/patches/$pkg.patch" ]]; then
      echo "[$ARCH] Applying custom patch for $pkg..."
      git -C "$AURDEST/$pkg" apply "$PWD/patches/$pkg.patch"
    elif [[ -x "$PWD/patches/$pkg.sh" ]]; then
      echo "[$ARCH] Executing custom patch script for $pkg..."
      "$PWD/patches/$pkg.sh" "$AURDEST/$pkg"
    fi
  fi
done

# Run sync
AUR_SYNC_ARGS=(
  -d "$REPO_NAME"
  --pacman-conf "$PACMAN_CONF"
  --makepkg-conf "$MAKEPKG_TEMP_CONF"
  --noview
  --noconfirm
  -r
  -C
)

# If NO_CHROOT is set, build without systemd-nspawn container
if [[ "${NO_CHROOT}" != "1" ]]; then
  AUR_SYNC_ARGS+=( -c -D "$CHROOT_DIR" )
fi

trap 'rm -f "$PACMAN_CONF" "$MAKEPKG_TEMP_CONF"' EXIT INT TERM
aur sync "${AUR_SYNC_ARGS[@]}" "${PACKAGES[@]}"
