"""`legal:check` over an app's directory: which files it reads, what it refuses and how it answers."""

from pathlib import Path

import pytest

from legal.check import check_app, main
from legal.section import LegalError

ZONE = "edge-fixture.invalid"
SECTION = '<h2 id="hopin">HopIn</h2>\n<p>Text</p>\n'


@pytest.fixture
def app(tmp_path: Path) -> Path:
    (tmp_path / "legal").mkdir()
    (tmp_path / "legal" / "datenschutz.html").write_text(SECTION)
    return tmp_path


def run(app: Path, capsys, key: str = "hopin") -> tuple[int, str, str]:
    status = main([key, str(app), ZONE])
    captured = capsys.readouterr()
    return status, captured.out, captured.err


def test_the_required_page_alone_passes(app, capsys):
    assert run(app, capsys) == (0, "legal:check: hopin valid: datenschutz\n", "")


def test_the_optional_page_is_checked_when_present(app, capsys):
    (app / "legal" / "nutzungsbedingungen.html").write_text(SECTION)

    assert run(app, capsys)[1] == "legal:check: hopin valid: datenschutz nutzungsbedingungen\n"


def test_a_missing_required_page_is_refused_by_name(app, capsys):
    (app / "legal" / "datenschutz.html").unlink()

    assert run(app, capsys) == (1, "", "legal: legal/datenschutz.html: is missing\n")


def test_a_link_in_place_of_a_file_is_refused(app, capsys):
    (app / "legal" / "nutzungsbedingungen.html").symlink_to("datenschutz.html")

    status, _, error = run(app, capsys)

    assert (status, error) == (1, "legal: legal/nutzungsbedingungen.html: is not a regular file\n")


def test_a_directory_in_place_of_a_file_is_refused(app, capsys):
    (app / "legal" / "nutzungsbedingungen.html").mkdir()

    assert run(app, capsys)[2].endswith("nutzungsbedingungen.html: is not a regular file\n")


def test_a_path_that_is_no_directory_is_refused(app, capsys):
    status, _, error = run(app / "legal" / "datenschutz.html", capsys)

    assert status == 1
    assert error.endswith("datenschutz.html: is not a directory\n")


def test_a_wrong_key_is_refused_with_the_line_and_without_the_text(app, capsys):
    status, _, error = run(app, capsys, key="other")

    assert status == 1
    assert error.startswith("legal: legal/datenschutz.html: line 1: ")
    assert "Text" not in error


def test_the_first_refusal_raises_from_check_app(app):
    (app / "legal" / "datenschutz.html").write_text('<h2 id="hopin">HopIn</h2>\n<img>\n')

    with pytest.raises(LegalError, match="line 2"):
        check_app("hopin", app, ZONE)


def test_a_wrong_number_of_arguments_prints_the_usage(capsys):
    assert main(["hopin"]) == 2
    assert "usage" in capsys.readouterr().err


def test_a_directory_link_that_leaves_the_app_is_refused(app, tmp_path_factory, capsys):
    outside = tmp_path_factory.mktemp("outside")
    (outside / "datenschutz.html").write_text(SECTION)
    (app / "legal").rename(app / "moved")
    (app / "legal").symlink_to(outside)

    assert run(app, capsys) == (1, "", "legal: legal/datenschutz.html: lies outside the directory\n")
