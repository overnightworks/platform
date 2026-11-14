#!/usr/bin/env bash
# On the pinned LiteLLM image, with no network and nothing sent upstream: a call through the router built from
# litellm-config.yaml's model_list to each text name that ends in -medium or -low sends that effort to Anthropic in the
# raw request, any other name sends none, and a request that names reasoning_effort (low) outranks the
# configured effort, as litellm-config.yaml says, so a gateway bump that drops the effort, changes the precedence or a
# name whose effort cannot be set goes red.
# Usage: tests/litellm/configured_effort_reaches_the_provider_request.sh
# Proves the four effort names of litellm-config.yaml.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
layer="$repository_root/infrastructure/litellm"
container="litellm-effort-cell-$$"
trap 'docker rm --force "$container" >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

image="$(yq 'select(.kind == "Deployment" and .metadata.name == "litellm") | .spec.template.spec.containers[].image |
  select(test("^ghcr[.]io/berriai/litellm:"))' "$layer/litellm.yaml")"
[ -n "$image" ] || fail "litellm.yaml holds no LiteLLM image"

report="$(timeout 300 docker run --name "$container" --rm --interactive --network none \
  --env LITELLM_LOCAL_MODEL_COST_MAP=True --volume "$layer/litellm-config.yaml:/config.yaml:ro" \
  --entrypoint python "$image" - <<'PYTHON' | sed -n 's/^SENT //p'
import asyncio, json as jsonlib, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import litellm, yaml

sent = []


class Recorder(BaseHTTPRequestHandler):
    def do_POST(self):
        sent.append(jsonlib.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        reply = b'{"type": "error", "error": {"type": "invalid_request_error", "message": "recorded, nothing is answered"}}'
        self.send_response(400)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *arguments):
        pass


recorder = ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
threading.Thread(target=recorder.serve_forever, daemon=True).start()
api_base = f"http://127.0.0.1:{recorder.server_port}"

model_list = yaml.safe_load(open("/config.yaml"))["model_list"]
for entry in model_list:
    entry["litellm_params"].update(api_key="sk-offline", api_base=api_base)
router = litellm.Router(model_list=[entry for entry in model_list if entry["model_name"].startswith("text/")],
                        num_retries=0, disable_cooldowns=True)


async def main():
    report = []
    for entry in model_list:
        name = entry["model_name"]
        if not name.startswith("text/"):
            continue
        for extra in ({}, {"reasoning_effort": "low"}):
            sent.clear()
            try:
                await router.acompletion(model=name, messages=[{"role": "user", "content": "x"}], **extra)
            except Exception:  # LiteLLM maps the recorder's error to its own; the count below judges the call
                pass
            if len(sent) != 1:
                sys.exit(f"{name}: {len(sent)} requests rendered, not 1")
            report.append({"name": name, "named_reasoning_effort": bool(extra),
                           "expected": "low" if extra else name.rpartition("-")[2] if name.endswith(("-medium", "-low")) else None,
                           "sent": sent[0].get("output_config", {}).get("effort")})
    print("SENT " + jsonlib.dumps(report))


asyncio.run(main())
PYTHON
)" || fail "the container did not render the requests"
[ -n "$report" ] || fail "the container reported no request"

mismatch="$(yq --input-format json '[.[] | select(.expected != .sent) | .name + " (reasoning_effort named: " + (.named_reasoning_effort | tostring) + ")"] | join(", ")' <<<"$report")"
[ -z "$mismatch" ] || fail "the effort sent to Anthropic differs from the configured one for: $mismatch"
echo "each of $(yq --input-format json 'length' <<<"$report") requests to the text names sent the effort its name ends in, none otherwise, and the request's reasoning_effort outranked it"
