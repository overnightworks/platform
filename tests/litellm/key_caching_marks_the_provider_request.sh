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

# The call goes through litellm.acompletion with the field the proxy copies from the key; the post is replaced by a
# recorder that raises, so that nothing leaves the process, and the container has no network besides.
rendered="$(timeout 300 docker run --name "$container" --rm --interactive --network none \
  --env LITELLM_LOCAL_MODEL_COST_MAP=True --entrypoint python "$image" - "${models[@]}" <<'PYTHON' | sed -n 's/^RENDERED //p'
import asyncio, json as jsonlib, sys
import litellm
from litellm.llms.custom_httpx.http_handler import AsyncHTTPHandler

sent = []


async def record(self, url, data=None, json=None, **kwargs):
    sent.append(data if data is not None else json)
    raise RuntimeError("recorded, nothing is sent")


AsyncHTTPHandler.post = record


async def render(model, flag):
    sent.clear()
    try:
        await litellm.acompletion(
            model=model, api_key="sk-offline", api_base="http://127.0.0.1:9", max_tokens=16, num_retries=0,
            enable_prompt_caching=flag,
            messages=[{"role": "system", "content": "You are an agent."},
                      {"role": "user", "content": "first"},
                      {"role": "assistant", "content": "ok"},
                      {"role": "user", "content": "second"}],
            tools=[{"type": "function", "function": {"name": "t", "description": "d",
                                                     "parameters": {"type": "object", "properties": {}}}}])
    except Exception:  # LiteLLM maps the recorder's error to its own; the count below judges the call
        pass
    if len(sent) != 1:
        sys.exit(f"{model}: {len(sent)} requests rendered, not 1")
    body = sent[0]
    return jsonlib.loads(body) if isinstance(body, (str, bytes)) else body


async def main():
    rendered = []
    for model in sys.argv[1:]:
        for flag in (True, False):
            rendered.append({"enable_prompt_caching": flag, "request": await render(model, flag)})
    print("RENDERED " + jsonlib.dumps(rendered))


asyncio.run(main())
PYTHON
)" || fail "the container did not render the requests"
[ "$(yq --input-format json 'length' <<<"$rendered")" = $((${#models[@]} * 2)) ] || fail "the container rendered other requests than asked: $rendered"

# marked <index>: the blocks of the rendered request that carry a cache_control, as "path type" lines.
marked() {
  yq --input-format json "
    .[$1].request | [(.system[] | select(has(\"cache_control\")) | \"system \" + .cache_control.type),
    (.messages[] | .content[] | select(has(\"cache_control\")) | \"message \" + .cache_control.type),
    (.tools[] | select(has(\"cache_control\")) | \"tool \" + .cache_control.type)] | join(\",\")" <<<"$rendered"
}
for index in "${!models[@]}"; do
  with="$((index * 2))" without="$((index * 2 + 1))"
  [ "$(marked "$with")" = "system ephemeral,message ephemeral" ] ||
    fail "${models[$index]}: enable_prompt_caching true did not mark the system text and the last message: $(marked "$with")"
  [ "$(yq --input-format json ".[$with].request | .messages[-1].content[-1].text + \"/\" + .system[-1].text" <<<"$rendered")" = "second/You are an agent." ] ||
    fail "${models[$index]}: the markers are not on the last message and the system text"
  [ -z "$(marked "$without")" ] || fail "${models[$index]}: enable_prompt_caching false still marked: $(marked "$without")"
done
echo "enable_prompt_caching true marks the system text and the last message of a call to each of ${#models[@]} Claude models and false marks nothing"
