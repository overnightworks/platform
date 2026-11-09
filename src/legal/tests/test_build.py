"""`legal:build` over a repository's frame and sections: what it writes, what it refuses and how it answers."""

import hashlib
import shutil
from datetime import date
from pathlib import Path

import pytest

from legal.build import BUILT_DIRECTORY, SECTIONS_DIRECTORY, STAND_FILE, main, read_frame, read_sections
from legal.pages import TEMPLATES, build_pages, frame_page_path, frame_template_path
from legal.section import PAGES

SHIPPED_FRAME = Path(__file__).parents[3] / "infrastructure" / "legal" / "frame"
ZONE = "edge-fixture.invalid"
GENERAL_TEXT = '<h2 id="recht">Recht</h2>\n<p>a</p>\n'
SERVICE_TEXT = '<h2 id="anmeldung">Anmeldung</h2>\n<p>s</p>\n'


@pytest.fixture
def repository(tmp_path: Path, monkeypatch) -> Path:
    monkeypatch.chdir(tmp_path)
    shutil.copytree(SHIPPED_FRAME, tmp_path / Path(frame_page_path("impressum")).parent)
    (tmp_path / BUILT_DIRECTORY).mkdir(parents=True)
    return tmp_path


def declare(repository: Path, entries: dict[str, tuple[date, str]]) -> None:
    text = "".join(
        f'["{key}"]\ndate = {day.isoformat()}\nsha256 = "{sha256}"\n' for key, (day, sha256) in entries.items()
    )
    (repository / STAND_FILE).write_text(text)


def section(repository: Path, key: str, text: str, day: date) -> tuple[str, tuple[date, str]]:
    path = repository / SECTIONS_DIRECTORY / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return key, (day, hashlib.sha256(text.encode()).hexdigest())


@pytest.fixture
def sections(repository: Path) -> dict[str, tuple[date, str]]:
    entries = dict(
        [
            section(repository, "allgemein/datenschutz.html", GENERAL_TEXT, date(2026, 3, 9)),
            section(repository, "allgemein/nutzungsbedingungen.html", GENERAL_TEXT, date(2026, 1, 2)),
            section(repository, "keycloak/datenschutz.html", SERVICE_TEXT, date(2026, 10, 27)),
        ]
    )
    declare(repository, entries)
    return entries


def written_files(repository: Path) -> list[str]:
    built = repository / BUILT_DIRECTORY
    return sorted(path.name for path in built.iterdir())


def refusal_of(repository: Path, capsys) -> str:
    assert main([ZONE]) == 1
    assert written_files(repository) == []
    return capsys.readouterr().err


def test_only_the_impressum_is_written_and_it_is_the_frames_page(repository, sections, capsys):
    assert main([ZONE]) == 0

    assert written_files(repository) == ["impressum.html"]
    assert (repository / BUILT_DIRECTORY / "impressum.html").read_bytes() == (
        SHIPPED_FRAME / "impressum.html"
    ).read_bytes()
    assert capsys.readouterr().err == ""


def test_a_page_prints_the_newest_declared_date_of_its_own_sections_in_german(repository, sections):
    pages = build_pages(read_frame(), read_sections(ZONE))

    assert "Stand: 27. Oktober 2026" in pages["datenschutz"]
    assert "Stand: 2. Januar 2026" in pages["nutzungsbedingungen"]
    assert "Stand" not in pages["impressum"]


@pytest.mark.parametrize(
    "relative",
    [frame_page_path(page) for page in PAGES] + [frame_template_path(name) for name in TEMPLATES],
)
def test_a_missing_frame_file_is_refused_by_name_and_nothing_is_written(
    repository, sections, capsys, relative
):
    (repository / relative).unlink()

    assert refusal_of(repository, capsys) == f"legal: {relative} is missing; the frame is required\n"


def test_an_unreadable_frame_file_is_refused_by_name_and_nothing_is_written(
    repository, sections, capsys
):
    relative = frame_page_path("impressum")
    (repository / relative).unlink()
    (repository / relative).mkdir()

    assert refusal_of(repository, capsys).startswith(f"legal: {relative}: cannot read it")


def test_a_frame_that_fails_its_check_is_refused_and_nothing_is_written(
    repository, sections, capsys
):
    page = repository / frame_page_path("datenschutz")
    page.write_text(page.read_text() + "$unknown")

    assert "unknown field $unknown" in refusal_of(repository, capsys)


def test_a_directory_that_is_no_unit_is_refused_by_name(repository, sections, capsys):
    section(repository, "hopin/datenschutz.html", GENERAL_TEXT, date(2026, 1, 1))

    message = refusal_of(repository, capsys)

    assert message.startswith(f"legal: {SECTIONS_DIRECTORY}/hopin: is no unit")


@pytest.mark.parametrize("name", ["datenschutz.txt", "impressum.html", "notes"])
def test_a_file_that_is_no_section_page_is_refused_by_name(repository, sections, capsys, name):
    (repository / SECTIONS_DIRECTORY / "keycloak" / name).write_text(SERVICE_TEXT)

    message = refusal_of(repository, capsys)

    assert message.startswith(f"legal: {SECTIONS_DIRECTORY}/keycloak/{name}: is no section page")


def test_a_section_without_a_stand_entry_is_refused_by_name(repository, sections, capsys):
    del sections["keycloak/datenschutz.html"]
    declare(repository, sections)

    message = refusal_of(repository, capsys)

    assert message == (
        f"legal: {SECTIONS_DIRECTORY}/keycloak/datenschutz.html: has no Stand in {STAND_FILE}\n"
    )


def test_a_stand_entry_without_a_file_is_refused_by_name(repository, sections, capsys):
    declare(repository, {**sections, "litellm/datenschutz.html": (date(2026, 1, 1), "0" * 64)})

    message = refusal_of(repository, capsys)

    assert message == f"legal: {STAND_FILE}: [litellm/datenschutz.html] names no section file\n"


def test_an_edited_section_is_refused_and_the_message_prints_the_new_sha256(
    repository, sections, capsys
):
    edited = SERVICE_TEXT + "<p>geändert</p>\n"
    (repository / SECTIONS_DIRECTORY / "keycloak" / "datenschutz.html").write_text(edited)

    message = refusal_of(repository, capsys)

    assert message.endswith(f"the file's is {hashlib.sha256(edited.encode()).hexdigest()}\n")
    assert message.startswith(f"legal: {SECTIONS_DIRECTORY}/keycloak/datenschutz.html: differs")


@pytest.mark.parametrize(
    "text",
    [
        "not toml",
        '["a"]\nsha256 = "x"\n',
        '["a"]\ndate = "2026-01-01"\nsha256 = "x"\n',
        '["a"]\ndate = 2026-01-01\n',
        "a = 1\n",
    ],
)
def test_a_stand_file_that_is_no_table_of_date_and_sha256_is_refused(
    repository, sections, capsys, text
):
    (repository / STAND_FILE).write_text(text)

    assert refusal_of(repository, capsys).startswith(f"legal: {STAND_FILE}: ")


def test_a_stand_file_that_is_no_utf8_is_refused(repository, sections, capsys):
    (repository / STAND_FILE).write_bytes(b"\xff")

    assert refusal_of(repository, capsys).startswith(f"legal: {STAND_FILE}: ")


def test_a_missing_stand_file_is_refused_by_name(repository, sections, capsys):
    (repository / STAND_FILE).unlink()

    assert refusal_of(repository, capsys) == f"legal: {STAND_FILE} is missing; the Stand is required\n"


def test_a_missing_sections_directory_is_refused_by_name(repository, capsys):
    declare(repository, {})

    assert refusal_of(repository, capsys).startswith(f"legal: {SECTIONS_DIRECTORY}: cannot read it")


def test_an_unreadable_section_is_refused_by_name(repository, sections, capsys):
    path = repository / SECTIONS_DIRECTORY / "keycloak" / "datenschutz.html"
    path.unlink()
    path.mkdir()

    assert refusal_of(repository, capsys).startswith(f"legal: {path.relative_to(repository)}: cannot read it")


def test_a_call_without_exactly_a_zone_prints_the_usage(capsys):
    assert main([]) == 2
    assert main(["a", "b"]) == 2

    assert capsys.readouterr().err == "usage: legal.build <zone>\n" * 2
