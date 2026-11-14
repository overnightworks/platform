#!/usr/bin/env bash
# On the pinned LiteLLM image, with no network and nothing sent upstream: the raw request LiteLLM's own transform makes for
# a call to each Claude model of litellm-config.yaml, as the proxy makes it for a key whose enable_prompt_caching is true,
# carries the provider's cache markers, and the same call with false carries none, so a gateway bump that stops marking
# goes red. LiteLLM v1.106.6 marks two points (AnthropicCacheControlHook.get_default_injection_points): the last block
# of the system text and the last block of the last message; each carries cache_control {"type": "ephemeral"}. The tools
# precede the system text in the provider's prefix, so the system marker covers them and no tool is marked.
# Usage: tests/litellm/key_caching_marks_the_provider_request.sh
# Proves docs/operations.md OPS-13.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
layer="$repository_root/infrastructure/litellm"
container="litellm-caching-cell-$$"
trap 'docker rm --force "$container" >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

image="$(yq 'select(.kind == "Deployment" and .metadata.name == "litellm") | .spec.template.spec.containers[].image |
  select(test("^ghcr[.]io/berriai/litellm:"))' "$layer/litellm.yaml")"
[ -n "$image" ] || fail "litellm.yaml holds no LiteLLM image"
mapfile -t models < <(yq '.model_list[].litellm_params.model | select(test("^anthropic/"))' "$layer/litellm-config.yaml")
[ "${#models[@]}" != 0 ] || fail "litellm-config.yaml names no Anthropic model"

# The call goes through litellm.acompletion with the field the proxy copies from the key, to an api_base that is a recorder
# on the container's own loopback, which answers every request with an error; nothing leaves the container, which has no
# network besides.
rendered="$(timeout 300 docker run --name "$container" --rm --interactive --network none \
  --env LITELLM_LOCAL_MODEL_COST_MAP=True --entrypoint python "$image" - "${models[@]}" <<'PYTHON' | sed -n 's/^RENDERED //p'
import asyncio, json as jsonlib, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import litellm

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


GROWING = [{"role": "system", "content": "You are an agent."},
           {"role": "user", "content": "first present"},
           {"role": "user", "content": "second present"},
           {"role": "user", "content": "third present"}]
MIXED = [{"role": "system", "content": "You are an agent."},
         {"role": "user", "content": "first"},
         {"role": "assistant", "content": "ok"},
         {"role": "user", "content": "second"}]


async def render(model, flag, messages):
    sent.clear()
    try:
        await litellm.acompletion(
            model=model, api_key="sk-offline", api_base=api_base, max_tokens=16, num_retries=0,
            enable_prompt_caching=flag,
            messages=messages,
            tools=[{"type": "function", "function": {"name": "t", "description": "d",
                                                     "parameters": {"type": "object", "properties": {}}}}])
    except Exception:  # LiteLLM maps the recorder's error to its own; the count below judges the call
        pass
    if len(sent) != 1:
        sys.exit(f"{model}: {len(sent)} requests rendered, not 1")
    return sent[0]


async def main():
    rendered = []
    for model in sys.argv[1:]:
        for flag, messages in ((True, MIXED), (False, MIXED), (True, GROWING)):
            rendered.append({"enable_prompt_caching": flag, "request": await render(model, flag, messages)})
    print("RENDERED " + jsonlib.dumps(rendered))


asyncio.run(main())
PYTHON
)" || fail "the container did not render the requests"
[ "$(yq --input-format json 'length' <<<"$rendered")" = $((${#models[@]} * 3)) ] || fail "the container rendered other requests than asked: $rendered"

# marked <index>: the blocks of the rendered request that carry a cache_control, as "path type" lines.
marked() {
  yq --input-format json "
    .[$1].request | [(.system[] | select(has(\"cache_control\")) | \"system \" + .cache_control.type),
    (.messages[] | .content[] | select(has(\"cache_control\")) | \"message \" + .cache_control.type),
    (.tools[] | select(has(\"cache_control\")) | \"tool \" + .cache_control.type)] | join(\",\")" <<<"$rendered"
}
for index in "${!models[@]}"; do
  with="$((index * 3))" without="$((index * 3 + 1))" growing="$((index * 3 + 2))"
  [ "$(marked "$with")" = "system ephemeral,message ephemeral" ] ||
    fail "${models[$index]}: enable_prompt_caching true did not mark the system text and the last message: $(marked "$with")"
  [ "$(yq --input-format json ".[$with].request | .messages[-1].content[-1].cache_control.type + \"/\" + .system[-1].cache_control.type" <<<"$rendered")" = "ephemeral/ephemeral" ] ||
    fail "${models[$index]}: the markers are not on the final block of the last message and of the system text"
  [ -z "$(marked "$without")" ] || fail "${models[$index]}: enable_prompt_caching false still marked: $(marked "$without")"
  # Three consecutive user messages stay three blocks, in the order and with the text sent, and only the last block of the
  # last message carries the marker; a merge into one block or a marker elsewhere fails here naming the structure.
  structure="$(yq --input-format json --output-format json --indent 0 ".[$growing].request |
    {\"messages\": [.messages[] | {\"role\": .role, \"blocks\": (.content | length),
    \"marked\": [.content[] | has(\"cache_control\")]}]}" <<<"$rendered")"
  [ "$(yq --input-format json ".[$growing].request | [.messages[].content[].text] | join(\"|\")" <<<"$rendered")" = "first present|second present|third present" ] ||
    fail "${models[$index]}: three consecutive user messages are not three separate blocks as sent: $structure"
  [ "$(yq --input-format json ".[$growing].request | [.messages[].content[] | has(\"cache_control\")] | map(select(.)) | length" <<<"$rendered")" = 1 ] &&
    [ "$(yq --input-format json ".[$growing].request | .messages[-1].content[-1].cache_control.type" <<<"$rendered")" = ephemeral ] ||
    fail "${models[$index]}: the marker is not on the last block of the last message alone: $structure"
done
echo "enable_prompt_caching true marks the system text and the last message of a call to each of ${#models[@]} Claude models and false marks nothing; three consecutive user messages stay three blocks with the marker on the last"
