#!/usr/bin/env python3
import argparse
import os
import subprocess
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


def repo_add(db_file: str, pkg_file: str) -> None:
    subprocess.run(('repo-add', db_file, pkg_file), check=True)


def repo_remove(db_file: str, pkg_name: str) -> None:
    subprocess.run(('repo-remove', db_file, pkg_name), check=True)


def find_obsolete_packages(db_file: str, packages: list[str], keep: list[str]) -> Iterable[str]:
    '''Identify obsolete packages in the database.

    `packages` are AUR names, kept along with their dependencies. `keep` names packages built
    from git repositories, kept as they are.
    '''
    active = {pkg.name for pkg in _load_packages(db_file)}
    active.difference_update(keep)
    if packages:
        cmd = ('aur', 'depends', '-n', *packages)
        depends = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
        print('Depends:', depends)
        for line in depends.splitlines():
            for field in line.split('\t'):
                if val := field.strip():
                    active.discard(val)
    return active


def main():
    parser = argparse.ArgumentParser(prog='auv.py')
    commands = parser.add_subparsers(dest='command', required=True)
    obsolete = commands.add_parser('obsolete')
    obsolete.add_argument('db_file')
    obsolete.add_argument('packages', nargs='*')
    obsolete.add_argument('--keep', action='append', default=[])
    args = parser.parse_args()

    for name in find_obsolete_packages(args.db_file, args.packages, args.keep):
        print('Removing obsolete package from database:', name)
        repo_remove(args.db_file, name)


if __name__ == '__main__':
    main()
