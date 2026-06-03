#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
from typing import TYPE_CHECKING

sys.path.append(ROOT := os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from auv import load_packages, repo_add, repo_remove

if TYPE_CHECKING:
    from collections.abc import Iterable

PKG_EXT = '.pkg.tar.zst'


def inspect_file(pkg_file: str) -> tuple[str, str]:
    proc = subprocess.run(('pacman', '-Qp', pkg_file), capture_output=True, text=True, check=True)
    name, version = proc.stdout.strip().split()[:2]
    return name, version


def list_pkgs(base_dir: str) -> Iterable[str]:
    try:
        files = os.listdir(base_dir)
    except FileNotFoundError:
        return ()
    return (filename for filename in files if filename.endswith(PKG_EXT))


def main():
    profile = sys.argv[1]

    repo_dir = f'repos/{profile}'
    state_dir = f'state/{profile}'
    profile_dir = f'profiles/{profile}'
    aurdest = 'clones'

    db_file = f'{repo_dir}/aur-{profile}.db.tar.zst'
    release_assets_path = f'{state_dir}/release-assets.txt'
    obsolete_assets_path = f'{state_dir}/obsolete-assets.txt'
    notify_path = f'{state_dir}/notify.txt'

    notify_lines: list[str] = []
    notify = notify_lines.append

    # Used for abnormal recovery events.
    def notify_warn(title: str, value: str):
        notify(f'• ⚠️ <b>{title}</b>: <code>{value}</code>')

    os.makedirs(state_dir, exist_ok=True)

    # Database reconciliation against release assets
    if os.path.exists(db_file) and (packages := load_packages(db_file)):
        # Force a rebuild of any package whose file is missing from the release.
        # The asset manifest must exist when the database exists.
        print('=== Reconciling database against release assets ===')
        with open(release_assets_path) as fp:
            release_assets = frozenset(file for line in fp if (file := line.strip()))

        to_rm = []
        signing = 'GPGKEY' in os.environ
        for name, pkg in packages.items():
            if pkg.filename not in release_assets:
                # Recover manually deleted assets.
                print(f'Asset {pkg.filename} missing; rebuilding {name}')
                notify_warn('Missing', name)
                to_rm.append(name)
            elif signing and f'{pkg.filename}.sig' not in release_assets:
                print(f'Signature {pkg.filename}.sig missing; rebuilding {name}')
                notify_warn('Missing signature', name)
                to_rm.append(name)
            elif name.endswith('-debug'):
                # Drop historical debug packages, which should have been excluded by `sync.sh`.
                print(f'Removing debug package {name}...')
                notify_warn('Debug', name)
                to_rm.append(name)

        for name in to_rm:
            repo_remove(db_file, name)
            del packages[name]
    else:
        print('No active packages.')
        packages = {}
        release_assets = ()

    print('=== Running package sync ===')
    subprocess.run((os.path.join(ROOT, 'sync.sh'), profile_dir), check=True)

    # Keep only the latest cached version of each package
    print('=== Cleaning up Pacman cache ===')
    subprocess.run(('sudo', 'paccache', '-rk1'), check=True)

    # Filenames with colons are unsupported by GitHub release assets and will be renamed
    # if uploaded as-is, causing a database mismatch and client 404s.
    print('=== Renaming package files with colons in filenames ===')
    for filename in list_pkgs(repo_dir):
        if ':' in filename:
            new_filename = filename.replace(':', '-colon-')
            pkg_file = os.path.join(repo_dir, filename)
            new_pkg_file = os.path.join(repo_dir, new_filename)

            pkg_name, ver = inspect_file(pkg_file)
            print(f'Renaming {filename} from {pkg_name} {ver} to {new_filename} in database...')

            repo_remove(db_file, pkg_name)
            shutil.move(pkg_file, new_pkg_file)
            if os.path.exists(sig_file := pkg_file + '.sig'):
                shutil.move(sig_file, new_pkg_file + '.sig')

            repo_add(db_file, new_pkg_file)

    # Reload the modified database packages into memory
    old_packages = packages
    packages = load_packages(db_file)

    # Drop AUR clones removed from the database
    if os.path.isdir(aurdest):
        print('=== Cleaning up obsolete AUR clones ===')
        for ent in os.scandir(aurdest):
            if ent.is_dir() and ent.name not in packages:
                print(f'Removing obsolete AUR clone: {ent.name}')
                shutil.rmtree(ent.path)

    # Produce obsolete list and state mutation events
    if packages:
        active_filenames = frozenset(pkg.filename for pkg in packages.values())

        # This is only generated when any active package exists, so we don't delete
        # the only remaining assets.
        if obsolete_assets := [
            asset
            for asset in release_assets
            if (base := asset.removesuffix('.sig')).endswith('.old')
            or (base.endswith(PKG_EXT) and base not in active_filenames)
        ]:
            print(f'Obsolete assets found: {', '.join(obsolete_assets)}')
            with open(obsolete_assets_path, 'w') as fp:
                fp.write('\n'.join(obsolete_assets))

        # Only freshly built packages have their .pkg files present.
        print('=== Detecting built packages ===')
        for filename in list_pkgs(repo_dir):
            pkg_file = os.path.join(repo_dir, filename)

            # Drop local package files no longer in the database, which should not happen
            # in clean CI anyway.
            if filename not in active_filenames:
                print(f'Deleting obsolete local package: {filename}')
                notify_warn('Obsolete file', filename)
                os.remove(pkg_file)
                if os.path.exists(sig_file := pkg_file + '.sig'):
                    os.remove(sig_file)
                continue

            pkg_name, new_ver = inspect_file(pkg_file)
            if old_pkg := old_packages.get(pkg_name):
                print(f'Updated: {pkg_name} ({old_pkg.version} -> {new_ver})')
                notify(f'• {pkg_name}: <code>{old_pkg.version}</code> → <code>{new_ver}</code>')
            else:
                print(f'New: {pkg_name} ({new_ver})')
                notify(f'• {pkg_name}: <code>{new_ver}</code>')

    print('=== Detecting deleted packages ===')
    for old_pkg_name in old_packages:
        if old_pkg_name not in packages:
            notify(f'• Deleted: {old_pkg_name}')
            print(f'Deleted: {old_pkg_name}')

    if notify_lines:
        with open(notify_path, 'w') as fp:
            fp.write('\n'.join(notify_lines))


if __name__ == '__main__':
    main()
