"""Runs in an app's image beside its SQLite database volume; standard library only.

`load` writes a verified copy into the live file through SQLite's backup API, one write
transaction of the file's own journal or WAL, so the file holds the old or the new database,
never a mix; its exit says whether that transaction began. `check` judges a restored copy by the
same rule `load` judges its source by, and exits 0 only when the copy passes. Each prints a count
and nothing else: no row value, no path. `copy` writes the live database to stdout as one
consistent file, for the backup that streams it, and prints nothing else.
"""

import hashlib
import sqlite3
import sys
from contextlib import ExitStack, closing
from enum import IntEnum
from pathlib import Path

# The script's verdict that an error no step of `load` placed occurred; CPython's own exit 1
# stays a crash.
VERDICT_EXIT = 3
# How long the load waits for another connection's lock before it gives up.
BUSY_SECONDS = 5.0
_BLOCKED = frozenset({sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED})


class LoadExit(IntEnum):
    """How `load` ended, when not with its count. No value is CPython's 1, the usage 2 or
    `main`'s catch-all `VERDICT_EXIT`, so an error no step of `load` placed never reads as
    unchanged."""

    UNFINISHED = 4  # the copy began and did not finish: SQLite keeps the old or the new content
    UNCHECKED = 5  # the copy is in; the check of the live file after it failed
    BUSY = 6  # another connection held the live file before the copy began: unchanged
    REFUSED = 7  # established before the copy began: the live content is unchanged


class LoadFailed(Exception):
    def __init__(self, exit_code: LoadExit) -> None:
        self.exit_code = exit_code
        super().__init__(exit_code.name)


def load(staged: Path, size: int, sha256: str, live: Path, table: str) -> int:
    """The staged copy, verified against the host's size and digest and holding rows in its key
    table, written into the live file whole; then the live file's row count, which equals the
    copy's. A missing live file is refused, never created."""
    with ExitStack() as connections:
        source, destination, expected = _prepared(connections, staged, size, sha256, live, table)
        try:
            source.backup(destination, pages=-1, progress=_abort_when_blocked)
        except sqlite3.Error as error:
            raise LoadFailed(LoadExit.UNFINISHED) from error
        try:
            rows = _checked_rows(destination, table)
        except sqlite3.Error as error:
            raise LoadFailed(LoadExit.UNCHECKED) from error
        if rows != expected:
            raise LoadFailed(LoadExit.UNCHECKED)
        return rows


def copy_live(live: Path) -> bytes:
    """The live database as of one moment, serialized. The file is opened read-only, so the copy
    is a reader of the WAL and writes or checkpoints nothing; the one `backup` step holds the read
    lock throughout, so a writer's transaction is in the copy whole or not at all. The copy is
    held in memory."""
    with (
        closing(
            sqlite3.connect(f"{live.as_uri()}?mode=ro", uri=True, timeout=BUSY_SECONDS)
        ) as source,
        closing(sqlite3.connect(":memory:")) as snapshot,
    ):
        source.backup(snapshot, pages=-1)
        return snapshot.serialize()


def check(copy: Path, table: str) -> int:
    """The row count of a copy whose integrity check answers exactly `ok` and whose key table
    holds rows; anything else raises. The copy is opened immutable, so a `-wal` file beside it is
    ignored: the check judges the one file a restic dump restores, which holds none."""
    with closing(_immutable(copy)) as connection:
        return _populated_rows(connection, table)


def _prepared(
    connections: ExitStack, staged: Path, size: int, sha256: str, live: Path, table: str
) -> tuple[sqlite3.Connection, sqlite3.Connection, int]:
    """The verified copy and the live file opened, the copy's row count, and what SQLite would
    refuse inside the copy established; the copy has not begun, so every failure here is a
    refusal."""
    try:
        _require_bytes(staged, size, sha256)
        source = connections.enter_context(closing(_immutable(staged)))
        destination = connections.enter_context(
            closing(
                sqlite3.connect(
                    f"{live.as_uri()}?mode=rw", uri=True, timeout=BUSY_SECONDS, isolation_level=None
                )
            )
        )
        expected = _populated_rows(source, table)
        _require_writable(source, destination)
    except (sqlite3.Error, OSError) as error:
        raise LoadFailed(LoadExit.REFUSED) from error
    return source, destination, expected


def _immutable(database: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"{database.as_uri()}?mode=ro&immutable=1", uri=True)


def _populated_rows(connection: sqlite3.Connection, table: str) -> int:
    """The row count of a database whose integrity check answers exactly `ok`; a missing key
    table or one without a row is an error, since a database that never held data is no copy."""
    rows = _checked_rows(connection, table)
    if rows == 0:
        raise sqlite3.DatabaseError("the key table holds no row")
    return rows


def _checked_rows(connection: sqlite3.Connection, table: str) -> int:
    if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
        raise sqlite3.DatabaseError("integrity_check")
    quoted = '"' + table.replace('"', '""') + '"'
    return connection.execute(f"SELECT count(*) FROM {quoted}").fetchone()[0]  # noqa: S608 - the table name is quoted by doubling its quotes


def _require_bytes(staged: Path, size: int, sha256: str) -> None:
    with staged.open("rb") as file:
        if hashlib.file_digest(file, "sha256").hexdigest() != sha256 or file.tell() != size:
            raise LoadFailed(LoadExit.REFUSED)


def _require_writable(source: sqlite3.Connection, destination: sqlite3.Connection) -> None:
    """What SQLite would refuse only inside the copy, established before it: a WAL file keeps its
    page size (sqlite.org/wal.html), and another connection's write lock. Reading the file first
    lets SQLite recover a hot journal or a stale WAL as at any open."""
    try:
        journal = destination.execute("PRAGMA journal_mode").fetchone()[0]
        page_sizes = {
            connection.execute("PRAGMA page_size").fetchone()[0]
            for connection in (source, destination)
        }
        if journal == "wal" and len(page_sizes) > 1:
            raise LoadFailed(LoadExit.REFUSED)
        destination.execute("BEGIN IMMEDIATE")
        destination.execute("ROLLBACK")
    except sqlite3.OperationalError as error:
        if error.sqlite_errorcode & 0xFF in _BLOCKED:
            raise LoadFailed(LoadExit.BUSY) from error
        raise


def _abort_when_blocked(status: int, _remaining: int, _pages: int) -> None:
    """CPython retries a blocked step forever; raising here ends the copy and rolls it back."""
    if status in _BLOCKED:
        raise sqlite3.OperationalError("the live database stayed locked")


def main(arguments: list[str]) -> int:
    try:
        match arguments:
            case ["load", staged, size, sha256, live, table]:
                rows = load(Path(staged), int(size), sha256, Path(live), table)
            case ["check", copy, table]:
                rows = check(Path(copy), table)
            case ["copy", live]:
                sys.stdout.buffer.write(copy_live(Path(live)))
                sys.stdout.buffer.flush()
                return 0
            case _:
                return 2
        sys.stdout.write(f"{rows}\n")
    except LoadFailed as failure:
        return failure.exit_code
    except (sqlite3.Error, OSError, ValueError):
        return VERDICT_EXIT
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
