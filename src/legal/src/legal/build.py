# ruff: noqa: T201 - the program's one output owner
"""`legal:build`: the legal pages built from the frame in the working directory, the Impressum written."""

import sys
from pathlib import Path

from legal.pages import (
    TEMPLATES,
    Frame,
    build_pages,
    frame_page_path,
    frame_template_path,
)
from legal.section import PAGES, LegalError

WRITTEN_PAGE = "impressum"
BUILT_DIRECTORY = "infrastructure/legal/built"


def read_frame() -> Frame:
    return Frame(
        {page: _read(frame_page_path(page)).decode() for page in PAGES},
        {name: _read(frame_template_path(name)).decode() for name in TEMPLATES},
    )


def _read(relative: str) -> bytes:
    try:
        return Path(relative).read_bytes()
    except FileNotFoundError as error:
        raise LegalError(f"{relative} is missing; the frame is required") from error
    except OSError as error:
        raise LegalError(f"{relative}: cannot read it ({error.strerror})") from error


def main(arguments: list[str]) -> int:
    if arguments:
        print("usage: legal.build", file=sys.stderr)
        return 2
    try:
        pages = build_pages(read_frame(), [])
    except LegalError as refused:
        print(refused, file=sys.stderr)
        return 1
    target = Path(BUILT_DIRECTORY) / f"{WRITTEN_PAGE}.html"
    target.write_bytes(pages[WRITTEN_PAGE].encode())
    print(f"legal:build: wrote {BUILT_DIRECTORY}/{WRITTEN_PAGE}.html")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
