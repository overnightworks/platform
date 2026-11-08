"""`legal:build` over a repository's frame: what it writes, what it refuses and how it answers."""

import shutil
from pathlib import Path

import pytest

from legal.build import BUILT_DIRECTORY, main
from legal.pages import TEMPLATES, frame_page_path, frame_template_path
from legal.section import PAGES

SHIPPED_FRAME = Path(__file__).parents[3] / "infrastructure" / "legal" / "frame"


@pytest.fixture
def repository(tmp_path: Path, monkeypatch) -> Path:
    monkeypatch.chdir(tmp_path)
    shutil.copytree(SHIPPED_FRAME, tmp_path / Path(frame_page_path("impressum")).parent)
    (tmp_path / BUILT_DIRECTORY).mkdir(parents=True)
    return tmp_path


def written_files(repository: Path) -> list[str]:
    built = repository / BUILT_DIRECTORY
    return sorted(path.name for path in built.iterdir())


def test_only_the_impressum_is_written_and_it_is_the_frames_page(repository, capsys):
    assert main([]) == 0

    assert written_files(repository) == ["impressum.html"]
    assert (repository / BUILT_DIRECTORY / "impressum.html").read_bytes() == (
        SHIPPED_FRAME / "impressum.html"
    ).read_bytes()
    assert capsys.readouterr().err == ""


@pytest.mark.parametrize(
    "relative",
    [frame_page_path(page) for page in PAGES] + [frame_template_path(name) for name in TEMPLATES],
)
def test_a_missing_frame_file_is_refused_by_name_and_nothing_is_written(
    repository, capsys, relative
):
    (repository / relative).unlink()

    assert main([]) == 1

    assert capsys.readouterr().err == f"legal: {relative} is missing; the frame is required\n"
    assert written_files(repository) == []


def test_an_unreadable_frame_file_is_refused_by_name_and_nothing_is_written(repository, capsys):
    relative = frame_page_path("impressum")
    (repository / relative).unlink()
    (repository / relative).mkdir()

    assert main([]) == 1

    assert capsys.readouterr().err.startswith(f"legal: {relative}: cannot read it")
    assert written_files(repository) == []


def test_a_frame_that_fails_its_check_is_refused_and_nothing_is_written(repository, capsys):
    page = repository / frame_page_path("datenschutz")
    page.write_text(page.read_text() + "$unknown")

    assert main([]) == 1

    assert "unknown field $unknown" in capsys.readouterr().err
    assert written_files(repository) == []


def test_a_call_with_an_argument_prints_the_usage(capsys):
    assert main(["."]) == 2

    assert capsys.readouterr().err.startswith("usage: legal.build")
