#!/usr/bin/env python3
import os
import subprocess
import sys
import tempfile
from typing import TYPE_CHECKING, NamedTuple

import pyalpm

if TYPE_CHECKING:
    from collections.abc import Iterable


class PackageInfo(NamedTuple):
    name: str
    version: str
    filename: str


def _load_packages(db_file: str) -> Iterable[PackageInfo]:
    if not os.path.isfile(db_file):
        return

    with tempfile.TemporaryDirectory(prefix='repo-scratch-') as scratch:
        os.mkdir(os.path.join(scratch, 'sync'))
        os.mkdir(os.path.join(scratch, 'local'))
        os.symlink(os.path.abspath(db_file), os.path.join(scratch, 'sync', 'repo.db'))

        db = pyalpm.Handle('/', scratch).register_syncdb('repo', 0)
        for pkg in db.pkgcache:
            pkg = PackageInfo(pkg.name, pkg.version, pkg.filename)
            print('Package:', pkg)
            yield pkg


def load_packages(db_file: str) -> dict[str, PackageInfo]:
    '''Load package metadata from pacman repository database.'''
    return {pkg.name: pkg for pkg in _load_packages(db_file)}


def repo_add(db_file: str, pkg_file: str) -> None:
    subprocess.run(('repo-add', db_file, pkg_file), check=True)


def repo_remove(db_file: str, pkg_name: str) -> None:
    subprocess.run(('repo-remove', db_file, pkg_name), check=True)


def find_obsolete_packages(db_file: str, packages: list[str]) -> Iterable[str]:
    '''Identify obsolete packages in the database.'''
    active = {pkg.name for pkg in _load_packages(db_file)}
    depends = subprocess.run(
        ('aur', 'depends', '-n', *packages), capture_output=True, text=True, check=True
    ).stdout
    print('Depends:', depends)
    for line in depends.splitlines():
        for field in line.split('\t'):
            if val := field.strip():
                active.discard(val)
    return active


def main():
    if len(sys.argv) < 3:
        sys.exit('Usage: auv.py obsolete <db_file> <package> [<package> ...]')

    action = sys.argv[1]
    if action == 'obsolete':
        db_file = sys.argv[2]
        packages = sys.argv[3:]
        if obsolete := find_obsolete_packages(db_file, packages):
            print(f'Removing obsolete packages from database: {', '.join(obsolete)}')
            for name in obsolete:
                repo_remove(db_file, name)


if __name__ == '__main__':
    main()
