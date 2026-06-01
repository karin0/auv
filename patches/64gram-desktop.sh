#!/bin/bash
# patches/64gram-desktop.sh: Modifies 64gram-desktop's PKGBUILD to apply a static patch
# specifically for build-time tools (tl-parser, generate_mime_types_gperf),
# allowing successful compilation on older/different host CPUs.

pkg_dir=$1
if [[ -z "$pkg_dir" || ! -d "$pkg_dir" ]]; then
  echo "Usage: $0 <package_directory>" >&2
  exit 1
fi

pkg_dir=$(realpath "$pkg_dir")
PKGBUILD_PATH="$pkg_dir/PKGBUILD"

if [[ ! -f "$PKGBUILD_PATH" ]]; then
  echo "Error: PKGBUILD not found in $pkg_dir" >&2
  exit 1
fi

# Locate our static patch file in our repository's patches directory
patches_dir=$(dirname "$(realpath "$0")")
patch_src="$patches_dir/64gram-desktop-host-tools.patch"

if [[ ! -f "$patch_src" ]]; then
  echo "Error: Static patch $patch_src not found" >&2
  exit 1
fi

echo "[64gram-desktop patch] Copying static patch to clone directory..."
cp "$patch_src" "$pkg_dir/64gram-desktop-host-tools.patch"

echo "[64gram-desktop patch] Patching PKGBUILD to inject static patch usage..."

# 1. Inject the patch into the beginning of the source array
sed -i '/source=(/a \        "64gram-desktop-host-tools.patch"' "$PKGBUILD_PATH"

# 2. Inject 'SKIP' into the beginning of the sha512sums array to match the source order
sed -i "/sha512sums=(/a \            'SKIP'" "$PKGBUILD_PATH"

# 3. Inject the patch application command into the prepare() function
cat << 'EOF' > "$pkg_dir/patch_injection.tmp"

    # AUV Patch: Apply static patch to force x86-64 compile options for host tools (Last-Argument Wins)
    echo "=== [AUV Patch] Applying host tools compilation option overrides ==="
    patch -Np1 -d "$srcdir/td" -i "$srcdir/64gram-desktop-host-tools.patch"
EOF

# Inject the logic using sed (matching the patch application inside prepare())
sed -i '/patch -Np1 -d Telegram\/lib_base/r '"$pkg_dir/patch_injection.tmp" "$PKGBUILD_PATH"
rm -f "$pkg_dir/patch_injection.tmp"

echo "[64gram-desktop patch] PKGBUILD patched successfully."
