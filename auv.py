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
    base: str


def _load_packages(db_file: str) -> Iterable[PackageInfo]:
    with tempfile.TemporaryDirectory(prefix='repo-scratch-') as scratch:
        os.mkdir(os.path.join(scratch, 'sync'))
        os.mkdir(os.path.join(scratch, 'local'))
        os.symlink(os.path.abspath(db_file), os.path.join(scratch, 'sync', 'repo.db'))

        db = pyalpm.Handle('/', scratch).register_syncdb('repo', 0)
        for pkg in db.pkgcache:
            pkg = PackageInfo(pkg.name, pkg.version, pkg.filename, pkg.base or pkg.name)
            print('Package:', pkg)
            yield pkg


def load_packages(db_file: str) -> dict[str, PackageInfo]:
    '''Load package metadata from pacman repository database.'''
    return {pkg.name: pkg for pkg in _load_packages(db_file)}


def _call_repo(cmd: list[str], *args: str) -> None:
    if gpg_key := os.environ.get('GPGKEY'):
        cmd.extend(('--sign', '--key', gpg_key))
    cmd.extend(args)
    subprocess.run(cmd, check=True)


def repo_add(db_file: str, pkg_file: str) -> None:
    cmd = ['repo-add']
    if os.path.exists(pkg_file + '.sig'):
        cmd.append('--include-sigs')
    return _call_repo(cmd, db_file, pkg_file)


def repo_remove(db_file: str, pkg_name: str) -> None:
    return _call_repo(['repo-remove'], db_file, pkg_name)


def find_obsolete_packages(db_file: str, packages: list[str]) -> Iterable[str]:
    '''Identify obsolete packages in the database.'''
    active = {pkg.name for pkg in _load_packages(db_file)}
    cmd = ('aur', 'depends', '-n', *packages)
    depends = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    print('Depends:', depends)
    for line in depends.splitlines():
        for field in line.split('\t'):
            if val := field.strip():
                active.discard(val)
    return active


def main():
    if len(sys.argv) < 3 or sys.argv[1] != 'obsolete':
        sys.exit('Usage: auv.py obsolete <db_file> <package> [<package> ...]')

    for name in find_obsolete_packages(db_file := sys.argv[2], sys.argv[3:]):
        print('Removing obsolete package from database:', name)
        repo_remove(db_file, name)


if __name__ == '__main__':
    main()
