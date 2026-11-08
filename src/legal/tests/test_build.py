"""`legal:build` over a repository's frame and sections: what it writes, what it refuses and how it answers."""

import hashlib
import shutil
from datetime import date
from pathlib import Path

import pytest

from legal.build import (
    APP_TEXTS_DIRECTORY,
    APP_TEXTS_FILE,
    BUILT_DIRECTORY,
    SECTIONS_DIRECTORY,
    STAND_FILE,
    main,
    read_app_texts,
    read_frame,
    read_sections,
)
from legal.pages import TEMPLATES, build_pages, frame_page_path, frame_template_path
from legal.section import PAGES

SHIPPED_FRAME = Path(__file__).parents[3] / "infrastructure" / "legal" / "frame"
ZONE = "edge-fixture.invalid"
GENERAL_TEXT = '<h2 id="recht">Recht</h2>\n<p>a</p>\n'
SERVICE_TEXT = '<h2 id="anmeldung">Anmeldung</h2>\n<p>s</p>\n'


def app_text(key: str) -> str:
    return f'<h2 id="{key}">{key}</h2>\n<p>text of {key}</p>\n'


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
    declare_apps(repository, {})
    return entries


AppEntries = dict[str, dict[str, tuple[date, str]]]  # the declared date and sha256 by app key and page


def declare_apps(repository: Path, entries: AppEntries, tags: dict[str, str] | None = None) -> None:
    text = ""
    for key, pages in entries.items():
        text += f'[{key}]\n' + (f'tag = "{tags[key]}"\n' if tags and key in tags else "")
        for page, (day, sha256) in pages.items():
            text += f'[{key}.{page}]\ndate = {day.isoformat()}\nsha256 = "{sha256}"\n'
    (repository / APP_TEXTS_FILE).write_text(text)


def app_file(repository: Path, key: str, page: str, text: str, day: date) -> tuple[date, str]:
    path = repository / APP_TEXTS_DIRECTORY / key / f"{page}.html"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return day, hashlib.sha256(text.encode()).hexdigest()


@pytest.fixture
def apps(repository: Path, sections) -> AppEntries:
    entries: AppEntries = {
        "songmaker": {
            "datenschutz": app_file(repository, "songmaker", "datenschutz", app_text("songmaker"), date(2026, 11, 5)),
        },
        "hopin": {
            "datenschutz": app_file(repository, "hopin", "datenschutz", app_text("hopin"), date(2026, 11, 6)),
            "nutzungsbedingungen": app_file(
                repository, "hopin", "nutzungsbedingungen", app_text("hopin"), date(2026, 11, 4)
            ),
        },
    }
    declare_apps(repository, entries, {"songmaker": "v1"})
    return entries


def written_files(repository: Path) -> list[str]:
    built = repository / BUILT_DIRECTORY
    return sorted(path.name for path in built.iterdir())


def refusal_of(repository: Path, capsys) -> str:
    assert main([ZONE]) == 1
    assert written_files(repository) == []
    return capsys.readouterr().err


def test_all_three_pages_are_written_and_the_impressum_is_the_frames_page(repository, sections, apps, capsys):
    assert main([ZONE]) == 0

    assert written_files(repository) == ["datenschutz.html", "impressum.html", "nutzungsbedingungen.html"]
    assert (repository / BUILT_DIRECTORY / "impressum.html").read_bytes() == (
        SHIPPED_FRAME / "impressum.html"
    ).read_bytes()
    assert capsys.readouterr().err == ""


def test_a_page_prints_the_newest_declared_date_of_its_sections_and_app_texts_in_german(
    repository, sections, apps
):
    pages = build_pages(read_frame(), read_sections(ZONE) + read_app_texts(ZONE))

    assert "Stand: 6. November 2026" in pages["datenschutz"]
    assert "Stand: 4. November 2026" in pages["nutzungsbedingungen"]
    assert "Stand" not in pages["impressum"]


def test_an_app_block_stands_after_the_services_in_the_order_of_its_anchor(repository, sections, apps):
    page = build_pages(read_frame(), read_sections(ZONE) + read_app_texts(ZONE))["datenschutz"]

    anchors = [page.index(f'id="{anchor}"') for anchor in ("anmeldung", "hopin", "songmaker")]
    assert anchors == sorted(anchors)
    assert "text of hopin" in page


def test_a_build_without_any_app_text_still_writes_the_pages(repository, sections, capsys):
    assert main([ZONE]) == 0


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


def app_refusal(repository: Path, capsys) -> str:
    return refusal_of(repository, capsys).removeprefix("legal: ")


@pytest.mark.parametrize("key", ["allgemein", "keycloak", "litellm", "speech-runtime"])
def test_an_app_key_that_a_section_unit_owns_is_refused_by_name(repository, sections, apps, capsys, key):
    entries = {**apps, key: {"datenschutz": app_file(repository, key, "datenschutz", app_text(key), date(2026, 1, 1))}}
    declare_apps(repository, entries)

    message = app_refusal(repository, capsys)

    assert message.startswith(f"{APP_TEXTS_FILE}: [{key}]") and "one owner" in message


def test_an_app_text_without_an_entry_is_refused_by_name(repository, sections, apps, capsys):
    del apps["hopin"]["nutzungsbedingungen"]
    declare_apps(repository, apps)

    message = app_refusal(repository, capsys)

    assert message == (
        f"{APP_TEXTS_DIRECTORY}/hopin/nutzungsbedingungen.html: has no entry in {APP_TEXTS_FILE}\n"
    )


def test_an_app_text_of_an_app_the_list_omits_is_refused_by_name(repository, sections, apps, capsys):
    app_file(repository, "presentator", "datenschutz", app_text("presentator"), date(2026, 1, 1))

    assert app_refusal(repository, capsys) == (
        f"{APP_TEXTS_DIRECTORY}/presentator/datenschutz.html: has no entry in {APP_TEXTS_FILE}\n"
    )


def test_an_entry_without_a_file_is_refused_by_name(repository, sections, apps, capsys):
    (repository / APP_TEXTS_DIRECTORY / "hopin" / "nutzungsbedingungen.html").unlink()

    assert app_refusal(repository, capsys) == (
        f"{APP_TEXTS_FILE}: [hopin.nutzungsbedingungen] names no file\n"
    )


def test_an_app_without_a_datenschutz_is_refused_by_name(repository, sections, apps, capsys):
    del apps["songmaker"]["datenschutz"]
    (repository / APP_TEXTS_DIRECTORY / "songmaker" / "datenschutz.html").unlink()
    declare_apps(repository, apps)

    assert app_refusal(repository, capsys) == f"{APP_TEXTS_FILE}: [songmaker] has no datenschutz\n"


def test_a_stale_app_text_is_refused_and_the_message_prints_the_new_sha256(repository, sections, apps, capsys):
    edited = app_text("hopin") + "<p>neu</p>\n"
    (repository / APP_TEXTS_DIRECTORY / "hopin" / "datenschutz.html").write_text(edited)

    message = app_refusal(repository, capsys)

    assert message.startswith(f"{APP_TEXTS_DIRECTORY}/hopin/datenschutz.html: differs")
    assert message.endswith(f"the file's is {hashlib.sha256(edited.encode()).hexdigest()}\n")


def test_an_app_text_that_is_no_page_of_its_app_is_refused_by_name(repository, sections, apps, capsys):
    (repository / APP_TEXTS_DIRECTORY / "hopin" / "impressum.html").write_text(app_text("hopin"))

    assert app_refusal(repository, capsys).startswith(f"{APP_TEXTS_DIRECTORY}/hopin/impressum.html: is no")


@pytest.mark.parametrize(
    "text",
    ["not toml", "hopin = 1\n", '[hopin]\ntag = 1\n', '[hopin]\nother = "x"\n', '[hopin.datenschutz]\ndate = 2026-01-01\n'],
)
def test_an_app_list_that_is_no_table_of_apps_is_refused(repository, sections, apps, capsys, text):
    (repository / APP_TEXTS_FILE).write_text(text)

    assert app_refusal(repository, capsys).startswith(f"{APP_TEXTS_FILE}: ")


def test_a_missing_app_list_is_refused_by_name(repository, sections, capsys):
    (repository / APP_TEXTS_FILE).unlink()

    assert app_refusal(repository, capsys) == f"{APP_TEXTS_FILE} is missing; the app list is required\n"


def test_an_app_page_that_is_unreadable_is_refused_by_name(repository, sections, apps, capsys):
    path = repository / APP_TEXTS_DIRECTORY / "hopin" / "datenschutz.html"
    path.unlink()
    path.mkdir()

    assert app_refusal(repository, capsys).startswith(f"{APP_TEXTS_DIRECTORY}/hopin/datenschutz.html: cannot read it")


def test_a_call_without_exactly_a_zone_prints_the_usage(capsys):
    assert main([]) == 2
    assert main(["a", "b"]) == 2

    assert capsys.readouterr().err == "usage: legal.build <zone>\n" * 2
