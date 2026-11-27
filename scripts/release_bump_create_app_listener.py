# ruff: noqa: T201 - the listener prints its page address on stdout and its refusal on stderr
"""Serve GitHub's App manifest flow on 127.0.0.1 and hand the new App's key to `gh secret set`, which alone holds it.

Usage: python3 -I release_bump_create_app_listener.py <name> <deadline seconds> <owner/repository> <environment> <secret>
Prints one line on stdout, the page's address, and then serves until one request carries the state it made, the
deadline passes or a check refuses. Exit 0: the key is stored. Exit 1: nothing is stored; the reason is on stderr and
holds no value of the code or of GitHub's answer.

The temporary code in the redirect converts into the key, client_secret and webhook_secret for an hour, so only this
process holds it: it reaches curl on stdin, never an argument, and the answer returns on a pipe from which only the key
goes on, to gh's stdin. The script starts this process under scripts/gh_login_environment.sh's allowlist and both
children inherit it, so no debug switch, proxy or token of the caller's shell can print the answer.
"""

import argparse
import ctypes
import hmac
import html
import http.server
import json
import re
import resource
import secrets
import subprocess
import sys
import time
import urllib.parse
from dataclasses import dataclass

PERMISSIONS = {"contents": "write", "pull_requests": "write", "metadata": "read"}
CODE_PATTERN = re.compile(r"[A-Za-z0-9_-]{1,100}")
PR_SET_DUMPABLE = 4


@dataclass(frozen=True)
class Target:
    name: str
    organisation: str
    repository: str
    environment: str
    secret: str


class Refusal(Exception):
    """A check that stops the run; its text names the check and never a value of GitHub's answer."""


def run_child(command: list[str], standard_input: bytes) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(  # noqa: S603 - the commands are built from fixed names and the arguments of the script
        command, input=standard_input, capture_output=True, check=False
    )


def manifest_of(target: Target, port: int) -> dict[str, object]:
    return {
        "name": target.name,
        "url": f"https://github.com/{target.organisation}/{target.repository}",
        "redirect_url": f"http://127.0.0.1:{port}/created",
        "public": False,
        "default_permissions": PERMISSIONS,
        "default_events": [],
    }


def page_of(target: Target, manifest: dict[str, object], state: str) -> bytes:
    action = f"https://github.com/organizations/{target.organisation}/settings/apps/new?state={state}"
    return (
        '<!doctype html><meta charset="utf-8"><title>Create the release App</title>'
        f'<form id="manifest" method="post" action="{html.escape(action)}">'
        f'<input type="hidden" name="manifest" value="{html.escape(json.dumps(manifest))}">'
        '<button>Continue to GitHub</button></form>'
        '<script>document.getElementById("manifest").submit()</script>'
    ).encode()


def convert(code: str) -> dict[str, object]:
    configuration = (
        f'url = "https://api.github.com/app-manifests/{code}/conversions"\n'
        'request = "POST"\nheader = "Content-Length: 0"\nheader = "Accept: application/vnd.github+json"\n'
        "silent\nfail\nmax-time = 60\n"
    )
    answer = run_child(["curl", "-q", "--config", "-"], configuration.encode())
    if answer.returncode != 0:
        raise Refusal(f"GitHub's conversion failed (curl exit {answer.returncode})")
    try:
        parsed = json.loads(answer.stdout)
    except ValueError as error:
        raise Refusal("GitHub's conversion answered no JSON") from error
    if not isinstance(parsed, dict):
        raise Refusal("GitHub's conversion answered no object")
    return parsed


def key_of(answer: dict[str, object], target: Target, manifest: dict[str, object]) -> str:
    owner = answer.get("owner")
    if answer.get("slug") != target.name:
        raise Refusal("the created App's slug differs from the name")
    if not isinstance(owner, dict) or owner.get("login") != target.organisation:
        raise Refusal("the created App's owner is not the organisation")
    if answer.get("permissions") != manifest["default_permissions"]:
        raise Refusal("the created App's permissions differ from the manifest's")
    if answer.get("events") != manifest["default_events"]:
        raise Refusal("the created App subscribes to events")
    key = answer.get("pem")
    if not isinstance(key, str) or not key:
        raise Refusal("the answer holds no key")
    return key


def store(key: str, target: Target) -> None:
    repository = f"{target.organisation}/{target.repository}"
    answer = run_child(["gh", "secret", "set", target.secret, "--env", target.environment, "--repo", repository], key.encode())
    if answer.returncode != 0:
        raise Refusal(f"gh secret set failed (exit {answer.returncode})")


class Listener(http.server.HTTPServer):
    def __init__(self, target: Target) -> None:
        super().__init__(("127.0.0.1", 0), Request)
        self.target = target
        self.state = secrets.token_urlsafe(32)
        self.manifest = manifest_of(target, self.server_port)
        self.finished = False
        self.refusal: Refusal | None = None

    def handle_error(self, request: object, client_address: object) -> None:
        self.finished = True
        self.refusal = Refusal(f"the listener failed on a request ({sys.exc_info()[0].__name__})")


class Request(http.server.BaseHTTPRequestHandler):
    server: Listener
    # A client that connects and sends nothing must not hold the single-threaded listener past its deadline.
    timeout = 10

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - the request line holds the code
        pass

    def reply(self, status: int, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - the name http.server calls
        address = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(address.query, keep_blank_values=True)
        if address.path == "/" and not address.query:
            self.reply(200, page_of(self.server.target, self.server.manifest, self.server.state))
        elif address.path == "/created" and self.carries_the_state(query):
            self.take(query.get("code", [""])[0])
        else:
            self.reply(400, b"")

    def carries_the_state(self, query: dict[str, list[str]]) -> bool:
        returned = query.get("state", [""])[0]
        return hmac.compare_digest(returned.encode(), self.server.state.encode())

    def take(self, code: str) -> None:
        try:
            if not CODE_PATTERN.fullmatch(code):
                raise Refusal("the redirect holds no code")
            target = self.server.target
            store(key_of(convert(code), target, self.server.manifest), target)
        except Refusal as refusal:
            self.server.refusal = refusal
            self.reply(500, b"The key was not stored. Return to the terminal.")
        else:
            self.reply(200, b"The key is stored. Install the App from the terminal's link.")
        self.server.finished = True


def keep_no_core_dump() -> None:
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if ctypes.CDLL(None, use_errno=True).prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0:
        raise OSError("prctl(PR_SET_DUMPABLE) failed")


def serve(target: Target, deadline_seconds: float) -> None:
    deadline = time.monotonic() + deadline_seconds
    with Listener(target) as listener:
        print(f"http://127.0.0.1:{listener.server_port}/", flush=True)
        while not listener.finished:
            listener.timeout = deadline - time.monotonic()
            if listener.timeout <= 0:
                raise Refusal(f"no redirect with the state came within {deadline_seconds:g} seconds")
            listener.handle_request()
        if listener.refusal is not None:
            raise listener.refusal


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("deadline_seconds", type=float)
    parser.add_argument("repository", help="<owner>/<repository>")
    parser.add_argument("environment")
    parser.add_argument("secret")
    arguments = parser.parse_args()
    organisation, repository = arguments.repository.split("/")
    target = Target(arguments.name, organisation, repository, arguments.environment, arguments.secret)
    keep_no_core_dump()
    try:
        serve(target, arguments.deadline_seconds)
    except Refusal as refusal:
        print(f"release_bump_create_app_listener: {refusal}; nothing was stored", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
