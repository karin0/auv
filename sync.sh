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
ENTRIES=()
mapfile -t ENTRIES < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$PACKAGES_FILE")

if (( ${#ENTRIES[@]} == 0 )); then
  echo "[$PROFILE] No packages defined, aborting." >&2
  exit 1
fi

# An entry with a URL scheme is a git repository holding a PKGBUILD and its .SRCINFO,
# and any other entry is an AUR package name.
PACKAGES=()
GIT_URLS=()
for entry in "${ENTRIES[@]}"; do
  if [[ $entry == *://* ]]; then
    GIT_URLS+=("$entry")
  else
    PACKAGES+=("$entry")
  fi
done

echo '=================================================='
echo "[$PROFILE] Starting sync for repository: $REPO_NAME"
echo "[$PROFILE] Packages: ${PACKAGES[*]}"
echo "[$PROFILE] Git repositories: ${GIT_URLS[*]}"
echo '=================================================='

# Set AURDEST for clones
export AURDEST="$PWD/clones"
mkdir -p "$AURDEST"

# Clone each git repository into the directory named after its pkgbase, as aurutils does for
# the AUR, so that the clone cleanup in build.py keeps it.
GIT_DIRS=()
KEEP_ARGS=()
for url in "${GIT_URLS[@]}"; do
  pkg_dir="$AURDEST/$(basename "$url" .git)"
  if [[ -d $pkg_dir ]]; then
    git -C "$pkg_dir" remote set-url origin "$url"
    git -C "$pkg_dir" fetch origin HEAD
    git -C "$pkg_dir" reset --hard FETCH_HEAD
    git -C "$pkg_dir" clean -df
  else
    git clone "$url" "$pkg_dir"
  fi

  pkgbase=$(sed -n 's/^pkgbase = //p' "$pkg_dir/.SRCINFO")
  if [[ $pkgbase != "$(basename "$pkg_dir")" ]]; then
    echo "[$PROFILE] $url holds pkgbase $pkgbase, which must match the repository name." >&2
    exit 1
  fi

  GIT_DIRS+=("$pkg_dir")
  while read -r pkgname; do
    KEEP_ARGS+=(--keep "$pkgname")
  done < <(sed -n 's/^pkgname = //p' "$pkg_dir/.SRCINFO")
done

# Ensure package database exists, preventing pacman from failing
mkdir -p "$REPO_DIR"
DB_FILE="$REPO_DIR/$REPO_NAME.db.tar.zst"
if [[ ! -f "$DB_FILE" ]]; then
  echo "[$PROFILE] Pre-initializing empty database for $REPO_NAME..."
  repo-add "$DB_FILE"
else
  # Reconcile database to drop obsolete packages (those deleted from packages file and their dependencies)
  "$(dirname "$0")/auv.py" obsolete "$DB_FILE" "${PACKAGES[@]}" "${KEEP_ARGS[@]}"
fi

# Generate custom pacman.conf. sign.sh signs the repository after the build, so pacman skips
# signature checks on it here.
cp /etc/pacman.conf "$PACMAN_CONF"

cat <<EOF >> "$PACMAN_CONF"

[$REPO_NAME]
SigLevel = Never
Server = file://$REPO_DIR
EOF

if [[ -n $GITHUB_REPOSITORY ]]; then
  echo "[$PROFILE] Adding release repo from $GITHUB_REPOSITORY"
  echo "Server = https://github.com/$GITHUB_REPOSITORY/releases/download/$PROFILE" >> "$PACMAN_CONF"
fi

sudo pacman --config "$PACMAN_CONF" -Syu --noconfirm

# Ensure `makepkg -s` uses the custom pacman.conf
cat <<EOF > "$PACMAN_WRAPPER"
#!/bin/bash
echo "> \$0 \$*" >&2
exec pacman --config '$PACMAN_CONF' "\$@"
EOF
chmod +x "$PACMAN_WRAPPER"
export PACMAN="$PACMAN_WRAPPER"

# Common options shared by both aur sync and aur build
AUR_ARGS=(
  -d "$REPO_NAME"
  --pacman-conf "$PACMAN_CONF"
  --makepkg-conf "$MAKEPKG_TEMP_CONF"
  --noconfirm
  -C
)
[[ -z $CI ]] && AUR_ARGS+=( -c -D "$CHROOT_DIR" )

# Find out which packages actually need to be updated/built
if (( ${#PACKAGES[@]} > 0 )); then
  echo "[$PROFILE] Syncing packages with ${AUR_ARGS[*]} ..."
  aur sync --nobuild --noview "${AUR_ARGS[@]}" "${PACKAGES[@]}" > "$BUILD_QUEUE"
fi

# Queue each git repository whose .SRCINFO version is absent from or newer than the database.
for pkg_dir in "${GIT_DIRS[@]}"; do
  srcinfo="$pkg_dir/.SRCINFO"
  epoch=$(sed -n 's/^\tepoch = //p' "$srcinfo")
  version="${epoch:+$epoch:}$(sed -n 's/^\tpkgver = //p' "$srcinfo")-$(sed -n 's/^\tpkgrel = //p' "$srcinfo")"
  pkgname=$(sed -n '0,/^pkgname = /s/^pkgname = //p' "$srcinfo")
  current=$(aur repo -c "$PACMAN_CONF" -d "$REPO_NAME" --list | awk -v name="$pkgname" '$1 == name { print $2 }')
  if [[ -z $current ]] || (( $(vercmp "$version" "$current") > 0 )); then
    echo "[$PROFILE] $pkgname ${current:-(new)} -> $version"
    echo "$pkg_dir" >> "$BUILD_QUEUE"
  fi
done

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
