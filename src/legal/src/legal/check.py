# ruff: noqa: T201 - the program's one output owner
"""`legal:check <key> <dir> <zone>`: the legal files of one app, judged by the section validator."""

import stat
import sys
from pathlib import Path

from legal.section import LegalError, parse_fragment, refusal

REQUIRED_PAGE = "datenschutz"
OPTIONAL_PAGE = "nutzungsbedingungen"


def read_page(directory: Path, page: str, required: bool) -> tuple[str, bytes] | None:
    """The file's name relative to `directory` and its bytes; None when an optional file is absent."""
    name = f"legal/{page}.html"
    root = directory.resolve()
    resolved = (root / name).resolve()
    if not resolved.is_relative_to(root):
        raise refusal(name, None, "lies outside the directory")
    try:
        mode = (root / name).lstat().st_mode
    except FileNotFoundError:
        if required:
            raise refusal(name, None, "is missing") from None
        return None
    if not stat.S_ISREG(mode):
        raise refusal(name, None, "is not a regular file")
    return name, resolved.read_bytes()


def check_app(key: str, directory: Path, zone: str) -> list[str]:
    """The pages that passed; the first refusal raises."""
    if not directory.is_dir():
        raise LegalError(f"{directory}: is not a directory")
    passed = []
    for page, required in ((REQUIRED_PAGE, True), (OPTIONAL_PAGE, False)):
        if (found := read_page(directory, page, required)) is not None:
            parse_fragment(found[0], found[1], key, zone)
            passed.append(page)
    return passed


def main(arguments: list[str]) -> int:
    if len(arguments) != 3:
        print("usage: legal.check <key> <dir> <zone>", file=sys.stderr)
        return 2
    key, directory, zone = arguments
    try:
        passed = check_app(key, Path(directory), zone)
    except LegalError as refused:
        print(refused, file=sys.stderr)
        return 1
    print(f"legal:check: {key} valid: {' '.join(passed)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
