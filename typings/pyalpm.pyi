# pyalpm ships no type information. This stub covers the API that auv uses.

class Package:
    name: str
    version: str
    filename: str
    base: str | None

class DB:
    pkgcache: list[Package]

class Handle:
    def __init__(self, root: str, dbpath: str) -> None: ...
    def register_syncdb(self, name: str, flags: int) -> DB: ...
