"""The exits of sqlite_copy.py's `load` and `check`, driven through `main` on files in a temporary directory."""

import contextlib
import hashlib
import importlib.util
import io
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "sqlite_copy.py"
TABLE = "users"
OLD_ROWS = ["old-a", "old-b"]
NEW_ROWS = ["new-a", "new-b", "new-c"]

specification = importlib.util.spec_from_file_location("sqlite_copy", SCRIPT)
sqlite_copy = importlib.util.module_from_spec(specification)
specification.loader.exec_module(sqlite_copy)

REFUSED = int(sqlite_copy.LoadExit.REFUSED)
BUSY = int(sqlite_copy.LoadExit.BUSY)
UNFINISHED = int(sqlite_copy.LoadExit.UNFINISHED)
UNCHECKED = int(sqlite_copy.LoadExit.UNCHECKED)


def make_database(path: Path, values: list[str], *, page_size: int = 4096, table: str = TABLE) -> None:
    with contextlib.closing(sqlite3.connect(path, isolation_level=None)) as connection:
        connection.execute(f"PRAGMA page_size={page_size}")
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute(f'CREATE TABLE "{table}" (name TEXT)')
        connection.executemany(f'INSERT INTO "{table}" VALUES (?)', [(value,) for value in values])  # noqa: S608 - a fixed test table name


def make_damaged_database(path: Path) -> None:
    """A database with a page overwritten, which its integrity check reports."""
    make_database(path, [f"row-{number:04d}-" + "x" * 100 for number in range(300)])
    content = bytearray(path.read_bytes())
    content[4096 * 2 : 4096 * 3] = b"\xff" * 4096
    path.write_bytes(content)
    if integrity_of_or_error(path) == [("ok",)]:
        raise AssertionError("the overwritten page left the database intact")


def names_in(path: Path) -> list[str]:
    with contextlib.closing(sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True)) as connection:
        return sorted(row[0] for row in connection.execute("SELECT name FROM users"))


def integrity_of(path: Path) -> list[tuple[str]]:
    with contextlib.closing(sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True)) as connection:
        return connection.execute("PRAGMA integrity_check").fetchall()


class LoadTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.live = self.directory / "live.sqlite3"
        make_database(self.live, OLD_ROWS)
        self.live_bytes = self.live.read_bytes()
        self.source = self.directory / "source.sqlite3"
        make_database(self.source, NEW_ROWS)

    def load(self, staged: Path | None = None, *, size: int | None = None, sha256: str | None = None,
             live: Path | None = None, table: str = TABLE) -> tuple[int, str]:
        staged = staged or self.source
        content = staged.read_bytes() if staged.exists() else b""
        arguments = [
            "load", str(staged), str(len(content) if size is None else size),
            hashlib.sha256(content).hexdigest() if sha256 is None else sha256,
            str(live or self.live), table,
        ]
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = sqlite_copy.main(arguments)
        return status, output.getvalue()

    def assert_live_unchanged(self) -> None:
        self.assertEqual(self.live.read_bytes(), self.live_bytes)
        self.assertEqual(names_in(self.live), sorted(OLD_ROWS))

    def test_a_good_copy_replaces_the_live_database_and_prints_the_source_count(self) -> None:
        status, output = self.load()
        self.assertEqual((status, output), (0, f"{len(NEW_ROWS)}\n"))
        self.assertEqual(names_in(self.live), sorted(NEW_ROWS))
        self.assertEqual(integrity_of(self.live), [("ok",)])

    def test_a_refusal_before_the_copy_exits_7_and_leaves_the_live_file_unchanged(self) -> None:
        damaged = self.directory / "damaged.sqlite3"
        make_damaged_database(damaged)
        without_table = self.directory / "without-table.sqlite3"
        make_database(without_table, NEW_ROWS, table="accounts")
        empty_table = self.directory / "empty-table.sqlite3"
        make_database(empty_table, [])
        other_page_size = self.directory / "other-page-size.sqlite3"
        make_database(other_page_size, NEW_ROWS, page_size=8192)
        broken_index = self.directory / "broken-index.sqlite3"
        make_database(broken_index, NEW_ROWS)
        with contextlib.closing(sqlite3.connect(broken_index, isolation_level=None)) as connection:
            connection.execute("CREATE INDEX users_name ON users(name)")
            connection.execute("PRAGMA writable_schema=ON")
            connection.execute("UPDATE sqlite_schema SET sql='CREATE INDEX users_name ON users(name DESC)' WHERE name='users_name'")
        cases = {
            "wrong digest": {"sha256": "0" * 64},
            "wrong size": {"size": len(self.source.read_bytes()) + 1},
            "damaged page": {"staged": damaged},
            "index that disagrees with its table": {"staged": broken_index},
            "missing key table": {"staged": without_table},
            "empty key table": {"staged": empty_table},
            "page size differs from a live file in WAL": {"staged": other_page_size},
            "missing staged file": {"staged": self.directory / "absent.sqlite3"},
            "missing live file": {"live": self.directory / "absent-live.sqlite3"},
        }
        for name, arguments in cases.items():
            with self.subTest(name):
                self.assertEqual(self.load(**arguments), (REFUSED, ""))
                self.assert_live_unchanged()
        self.assertFalse((self.directory / "absent-live.sqlite3").exists())

    def test_another_connection_holding_the_write_lock_exits_6_and_leaves_the_live_file_unchanged(self) -> None:
        with (
            contextlib.closing(sqlite3.connect(self.live, isolation_level=None)) as holder,
            mock.patch.object(sqlite_copy, "BUSY_SECONDS", 0.05),
        ):
            holder.execute("BEGIN IMMEDIATE")
            self.assertEqual(self.load(), (BUSY, ""))
        self.assert_live_unchanged()

    def test_a_failure_inside_the_copy_exits_4(self) -> None:
        class BackupFails(sqlite3.Connection):
            def backup(self, *arguments, **keywords) -> None:
                raise sqlite3.OperationalError("disk I/O error")

        with self.connections_as(BackupFails):
            self.assertEqual(self.load(), (UNFINISHED, ""))

    def test_a_check_of_the_live_file_that_fails_after_the_copy_exits_5(self) -> None:
        class CheckFails(sqlite3.Connection):
            copied = False

            def backup(self, *arguments, **keywords) -> None:
                super().backup(*arguments, **keywords)
                CheckFails.copied = True

            def execute(self, statement, *arguments):
                if CheckFails.copied:
                    raise sqlite3.DatabaseError("database disk image is malformed")
                return super().execute(statement, *arguments)

        with self.connections_as(CheckFails):
            self.assertEqual(self.load(), (UNCHECKED, ""))

    def test_a_live_count_that_differs_from_the_source_count_exits_5(self) -> None:
        class CountDiffers(sqlite3.Connection):
            copied = False

            def backup(self, *arguments, **keywords) -> None:
                super().backup(*arguments, **keywords)
                CountDiffers.copied = True

            def execute(self, statement, *arguments):
                if CountDiffers.copied and statement.startswith("SELECT count"):
                    return super().execute("SELECT 0")
                return super().execute(statement, *arguments)

        with self.connections_as(CountDiffers):
            self.assertEqual(self.load(), (UNCHECKED, ""))

    def test_arguments_that_fit_no_command_exit_2_and_a_size_that_is_no_number_exits_3(self) -> None:
        self.assertEqual(sqlite_copy.main([]), 2)
        self.assertEqual(sqlite_copy.main(["load", "only", "three", "arguments"]), 2)
        self.assertEqual(self.load(size="many"), (int(sqlite_copy.VERDICT_EXIT), ""))

    def connections_as(self, factory: type[sqlite3.Connection]):
        real_connect = sqlite3.connect
        return mock.patch.object(
            sqlite_copy.sqlite3, "connect", lambda *arguments, **keywords: real_connect(*arguments, factory=factory, **keywords)
        )


class CheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(self.enterContext(tempfile.TemporaryDirectory()))

    def check(self, copy: Path, table: str = TABLE) -> tuple[int, str]:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = sqlite_copy.main(["check", str(copy), table])
        return status, output.getvalue()

    def test_an_intact_copy_with_rows_exits_0_and_prints_its_count(self) -> None:
        copy = self.directory / "intact.sqlite3"
        make_database(copy, NEW_ROWS)
        self.assertEqual(self.check(copy), (0, f"{len(NEW_ROWS)}\n"))

    def test_a_copy_that_is_damaged_lacks_its_key_table_or_holds_no_row_there_exits_non_zero_and_prints_nothing(self) -> None:
        copies = {
            "damaged page": (make_damaged_database, {}),
            "missing key table": (make_database, {"values": NEW_ROWS, "table": "accounts"}),
            "empty key table": (make_database, {"values": []}),
        }
        for name, (make, arguments) in copies.items():
            with self.subTest(name):
                copy = self.directory / f"{name}.sqlite3"
                make(copy, **arguments)
                status, output = self.check(copy)
                self.assertNotEqual(status, 0)
                self.assertEqual(output, "")


def integrity_of_or_error(path: Path) -> list[tuple[str]]:
    try:
        return integrity_of(path)
    except sqlite3.Error as error:
        return [(str(error),)]


if __name__ == "__main__":
    unittest.main()
