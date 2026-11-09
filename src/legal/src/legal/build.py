# ruff: noqa: T201 - the program's one output owner
"""`legal:build`: the legal pages built from the frame, the sections and the app texts in the working directory, all three written."""

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

LEGAL_DIRECTORY = "infrastructure/legal"
BUILT_DIRECTORY = f"{LEGAL_DIRECTORY}/built"
SECTIONS_DIRECTORY = f"{LEGAL_DIRECTORY}/sections"
STAND_FILE = f"{LEGAL_DIRECTORY}/stand.toml"
APP_TEXTS_DIRECTORY = f"{LEGAL_DIRECTORY}/app-texts"
APP_TEXTS_FILE = f"{LEGAL_DIRECTORY}/app-texts.toml"
TAG_FIELD = "tag"  # read by the cell that proves the copies equal their release, not by the build
REQUIRED_APP_PAGE = "datenschutz"
GENERAL_UNIT = "allgemein"
SECTION_PAGES = ("datenschutz", "nutzungsbedingungen")
# The anchor of each of edge's own services; the key is its directory under the sections.
SERVICE_ANCHORS = {
    "keycloak": "anmeldung",
    "litellm": "agent-dienst",
    "speech": "sprachdienst",
}

Stand = dict[str, tuple[date, str]]  # the declared date and sha256 by section path under the sections
AppStand = dict[str, Stand]  # the same by app key and page


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


def _read_toml(file: str, required: str) -> dict:
    try:
        return tomllib.loads(_read(file, required).decode())
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as error:
        raise LegalError(f"{file}: {error}") from error


def _declared(file: str, name: str, entry: object) -> tuple[date, str]:
    day = entry.get("date") if isinstance(entry, dict) else None
    sha256 = entry.get("sha256") if isinstance(entry, dict) else None
    if type(day) is not date or not isinstance(sha256, str):
        raise LegalError(f"{file}: [{name}] needs a date and a sha256")
    return day, sha256


def _read_stand() -> Stand:
    declared = _read_toml(STAND_FILE, "the Stand")
    return {key: _declared(STAND_FILE, key, entry) for key, entry in declared.items()}


def _verified_date(shown: str, data: bytes, declared: tuple[date, str] | None, noun: str, file: str) -> date:
    if declared is None:
        raise refusal(shown, None, f"has no {noun} in {file}")
    sha256 = hashlib.sha256(data).hexdigest()
    if declared[1] != sha256:
        raise refusal(
            shown, None, f"differs from the sha256 its {noun} declares; the file's is {sha256}"
        )
    return declared[0]


def _section_page(path: Path) -> str:
    if path.suffix != ".html" or path.stem not in SECTION_PAGES:
        raise refusal(
            path.as_posix(), None, f"is no section page; the pages are {' and '.join(SECTION_PAGES)}"
        )
    return path.stem


def _read_section(path: Path, stand: Stand, zone: str) -> Block:
    shown = path.as_posix()
    unit, page = path.parent.name, _section_page(path)
    data = _read(shown, "the section")
    day = _verified_date(shown, data, stand.get(_key(shown)), "Stand", STAND_FILE)
    if unit == GENERAL_UNIT:
        return Block(shown, page, BlockKind.GENERAL, parse_general(shown, data, zone), day)
    parsed = parse_fragment(shown, data, SERVICE_ANCHORS[unit], zone)
    return Block(shown, page, BlockKind.SERVICE, parsed, day)


def read_app_texts(zone: str) -> list[Block]:
    """Every app's texts under the app texts directory with their declared date, one block per app and page."""
    declared = _read_app_list()
    directory = Path(APP_TEXTS_DIRECTORY)
    on_disk = [unit.name for unit in _listing(directory)] if directory.is_dir() else []
    blocks: list[Block] = []
    for key in sorted(set(declared) | set(on_disk)):
        if key == GENERAL_UNIT or key in SERVICE_ANCHORS:
            raise LegalError(f"{APP_TEXTS_FILE}: [{key}] is a unit of the sections; a text has one owner")
        entries = declared.get(key, {})
        files = _listing(directory / key) if key in on_disk else []
        blocks.extend(_read_app_text(path, key, entries, zone) for path in files)
        missing = sorted(set(entries) - {path.stem for path in files})
        if missing:
            raise LegalError(f"{APP_TEXTS_FILE}: [{key}.{missing[0]}] names no file")
        if REQUIRED_APP_PAGE not in {path.stem for path in files}:
            raise LegalError(f"{APP_TEXTS_FILE}: [{key}] has no {REQUIRED_APP_PAGE}")
    return blocks


def _read_app_list() -> AppStand:
    listed = _read_toml(APP_TEXTS_FILE, "the app list")
    apps: AppStand = {}
    for key, table in listed.items():
        if not isinstance(table, dict):
            raise LegalError(f"{APP_TEXTS_FILE}: [{key}] is no table of pages")
        apps[key] = {}
        for name, entry in table.items():
            if name == TAG_FIELD and isinstance(entry, str):
                continue
            if name not in SECTION_PAGES:
                raise LegalError(f"{APP_TEXTS_FILE}: [{key}] holds {name}, which is no page or tag")
            apps[key][name] = _declared(APP_TEXTS_FILE, f"{key}.{name}", entry)
    return apps


def _read_app_text(path: Path, key: str, entries: Stand, zone: str) -> Block:
    shown = path.as_posix()
    page = _section_page(path)
    data = _read(shown, "the app text")
    day = _verified_date(shown, data, entries.get(page), "entry", APP_TEXTS_FILE)
    return Block(shown, page, BlockKind.APP, parse_fragment(shown, data, key, zone), day)


def main(arguments: list[str]) -> int:
    if len(arguments) != 1:
        print("usage: legal.build <zone>", file=sys.stderr)
        return 2
    try:
        pages = build_pages(read_frame(), read_sections(arguments[0]) + read_app_texts(arguments[0]))
    except LegalError as refused:
        print(refused, file=sys.stderr)
        return 1
    for page, text in pages.items():
        (Path(BUILT_DIRECTORY) / f"{page}.html").write_bytes(text.encode())
        print(f"legal:build: wrote {BUILT_DIRECTORY}/{page}.html")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
