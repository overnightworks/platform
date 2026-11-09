# ruff: noqa: T201 - the program's one output owner
"""`legal:build`: the legal pages built from the frame and the sections in the working directory, the Impressum written."""

import hashlib
import sys
import tomllib
from datetime import date
from pathlib import Path

from legal.pages import (
    TEMPLATES,
    Block,
    BlockKind,
    Frame,
    build_pages,
    frame_page_path,
    frame_template_path,
)
from legal.section import PAGES, LegalError, parse_fragment, parse_general, refusal

WRITTEN_PAGE = "impressum"
LEGAL_DIRECTORY = "infrastructure/legal"
BUILT_DIRECTORY = f"{LEGAL_DIRECTORY}/built"
SECTIONS_DIRECTORY = f"{LEGAL_DIRECTORY}/sections"
STAND_FILE = f"{LEGAL_DIRECTORY}/stand.toml"
GENERAL_UNIT = "allgemein"
SECTION_PAGES = ("datenschutz", "nutzungsbedingungen")
# The anchor of each of edge's own services; the key is its directory under the sections.
SERVICE_ANCHORS = {
    "keycloak": "anmeldung",
    "litellm": "agent-dienst",
    "speech-runtime": "sprachdienst",
}

Stand = dict[str, tuple[date, str]]  # the declared date and sha256 by section path under the sections


def read_frame() -> Frame:
    return Frame(
        {page: _read(frame_page_path(page), "the frame").decode() for page in PAGES},
        {name: _read(frame_template_path(name), "the frame").decode() for name in TEMPLATES},
    )


def _read(relative: str, required: str) -> bytes:
    try:
        return Path(relative).read_bytes()
    except FileNotFoundError as error:
        raise LegalError(f"{relative} is missing; {required} is required") from error
    except OSError as error:
        raise LegalError(f"{relative}: cannot read it ({error.strerror})") from error


def read_sections(zone: str) -> list[Block]:
    """Every section under the sections directory with its declared Stand."""
    stand = _read_stand()
    blocks = [_read_section(path, stand, zone) for path in _section_files()]
    orphans = sorted(set(stand) - {_key(block.path) for block in blocks})
    if orphans:
        raise LegalError(f"{STAND_FILE}: [{orphans[0]}] names no section file")
    return blocks


def _key(path: str) -> str:
    return path.removeprefix(f"{SECTIONS_DIRECTORY}/")


def _listing(directory: Path) -> list[Path]:
    try:
        return sorted(directory.iterdir())
    except OSError as error:
        raise LegalError(f"{directory}: cannot read it ({error.strerror})") from error


def _section_files() -> list[Path]:
    files: list[Path] = []
    for unit in _listing(Path(SECTIONS_DIRECTORY)):
        if unit.name != GENERAL_UNIT and unit.name not in SERVICE_ANCHORS:
            raise LegalError(f"{unit}: is no unit; the units are {GENERAL_UNIT} and the services")
        files.extend(_listing(unit))
    return files


def _read_stand() -> Stand:
    try:
        declared = tomllib.loads(_read(STAND_FILE, "the Stand").decode())
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as error:
        raise LegalError(f"{STAND_FILE}: {error}") from error
    stand: Stand = {}
    for key, entry in declared.items():
        day = entry.get("date") if isinstance(entry, dict) else None
        sha256 = entry.get("sha256") if isinstance(entry, dict) else None
        if type(day) is not date or not isinstance(sha256, str):
            raise LegalError(f"{STAND_FILE}: [{key}] needs a date and a sha256")
        stand[key] = (day, sha256)
    return stand


def _read_section(path: Path, stand: Stand, zone: str) -> Block:
    shown = path.as_posix()
    unit, page = path.parent.name, path.stem
    if path.suffix != ".html" or page not in SECTION_PAGES:
        raise refusal(shown, None, f"is no section page; the pages are {' and '.join(SECTION_PAGES)}")
    data = _read(shown, "the section")
    declared = stand.get(_key(shown))
    if declared is None:
        raise refusal(shown, None, f"has no Stand in {STAND_FILE}")
    sha256 = hashlib.sha256(data).hexdigest()
    if declared[1] != sha256:
        raise refusal(
            shown, None, f"differs from the sha256 its Stand declares; the file's is {sha256}"
        )
    if unit == GENERAL_UNIT:
        return Block(shown, page, BlockKind.GENERAL, parse_general(shown, data, zone), declared[0])
    parsed = parse_fragment(shown, data, SERVICE_ANCHORS[unit], zone)
    return Block(shown, page, BlockKind.SERVICE, parsed, declared[0])


def main(arguments: list[str]) -> int:
    if len(arguments) != 1:
        print("usage: legal.build <zone>", file=sys.stderr)
        return 2
    try:
        pages = build_pages(read_frame(), read_sections(arguments[0]))
    except LegalError as refused:
        print(refused, file=sys.stderr)
        return 1
    target = Path(BUILT_DIRECTORY) / f"{WRITTEN_PAGE}.html"
    target.write_bytes(pages[WRITTEN_PAGE].encode())
    print(f"legal:build: wrote {BUILT_DIRECTORY}/{WRITTEN_PAGE}.html")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
