# ruff: noqa: T201 - the program's one output owner
"""A stand-in for LiteLLM's gateway, for tests/litellm/gateway_probe_*.sh: it keeps keys, a prompt cache and a spend log in
memory and answers the routes the gateway probe uses, as a healthy gateway should, except where the test names a fault.

Usage: fake_gateway.py <master key> <faults, comma separated> <seeded keys>
Writes the loopback port it listens on as its first line, then serves until it is ended. A GET on /__keys lists the key
aliases it holds, without authorization.

Faults: delete_fails (a key deletion answers 500), messages_ignores_budget (/v1/messages passes a key past its budget),
unnamed_budget_refusal (a refusal for the budget says nothing of a budget), short_read (a cache hit reads twenty tokens
less than it held), refuse_zero (max_tokens 0 is refused with 400), drop_row (one answered call has no spend log row),
chat_fails (the chat route answers 500), dear_writes (a cache write costs five times the price /model/info names),
spendy_calls (each answered call costs 0.025 USD), no_cache (no route caches: usage reports no write and no read and the whole
prompt as input), dear_misses (a call that reads less than 500000 tokens of a prompt of 500000 or more costs 3.3 USD),
heavy_first_call (the first answered call costs 2.95 USD), small_model_limit (/model/info names 100000 as the most input
tokens of a model), mixed_refused (a tool message of text and a tool reference is refused with 400), reference_ignored (a tool
reference loads nothing: the reply calls no tool and the definition is not billed).

A tool with defer_loading is billed only once a tool message references it, and then the reply calls it with the text of that
message's last word and the first value of each enum of its definition.
"""

import hashlib
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MASTER_KEY, FAULTS, SEEDED = sys.argv[1], set(filter(None, sys.argv[2].split(","))), int(sys.argv[3])
MODELS = ["text/sonnet", "text/haiku", "text/sonnet-medium", "text/haiku-fast", "image/flare"]
WRITE_PRICE = 1e-5 if "dear_writes" in FAULTS else 2e-6
CALL_SPEND = 0.025 if "spendy_calls" in FAULTS else 0.001
MISS_SPEND, MISS_TOKENS, HEAVY_SPEND = 3.3, 500000, 2.95
MODEL_INFO = {"max_input_tokens": 100000 if "small_model_limit" in FAULTS else 1000000, "input_cost_per_token": 2e-6, "output_cost_per_token": 1e-5,
              "cache_read_input_token_cost": 1e-7, "cache_creation_input_token_cost": WRITE_PRICE,
              "cache_creation_input_token_cost_above_1hr": 4e-6, "unset": None}
PAGE_LIMIT = 100
state = {"keys": {}, "cache": {}, "inflight": {}, "logs": [], "calls": 0, "answered": 0}
lock = threading.Lock()


def key_hash(value):
    return hashlib.sha256(value.encode()).hexdigest()


for number in range(SEEDED):
    state["keys"][key_hash("seed-%d" % number)] = {"key_alias": "an-app-key-%d" % number, "spend": 0.0}
if SEEDED:
    for alias in ("gateway-probe-1-2-main", "gateway-probe-3-4-budget"):
        state["keys"][key_hash(alias)] = {"key_alias": alias, "spend": 0.0}


def tool_name(tool):
    return tool.get("name") or tool["function"]["name"]


def tool_messages(body):
    return [message for message in body.get("messages", []) if message.get("role") == "tool" and isinstance(message.get("content"), list)]


def referenced_names(body):
    return {part["tool_name"] for message in tool_messages(body) for part in message["content"] if part.get("type") == "tool_reference"}


def mixes_text_and_reference(body):
    return any({part.get("type") for part in message["content"]} >= {"text", "tool_reference"} for message in tool_messages(body))


def faulty_refusal(body, max_tokens):
    """The message with which a fault refuses the request, or None."""
    if max_tokens == 0 and "refuse_zero" in FAULTS:
        return "max_tokens must be positive"
    if "mixed_refused" in FAULTS and mixes_text_and_reference(body):
        return "tool result content mixes text and tool references"
    return None


def loaded_call(body):
    """The call a reply makes to the tool that a tool message loads, or None."""
    for message in tool_messages(body):
        words = " ".join(part["text"] for part in message["content"] if part.get("type") == "text").split()
        for tool in body.get("tools") or []:
            if tool_name(tool) in referenced_names(body) and words:
                properties = tool["function"]["parameters"]["properties"]
                arguments = {name: spec["enum"][0] if "enum" in spec else words[-1] for name, spec in properties.items()}
                return {"id": "call_loaded", "type": "function", "function": {"name": tool_name(tool), "arguments": json.dumps(arguments)}}
    return None


class Gateway(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *arguments):
        pass

    def send_json(self, status, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def bearer(self):
        return (self.headers.get("Authorization") or "").replace("Bearer ", "")

    def do_GET(self):
        path = self.path
        if path == "/__keys":
            return self.send_json(200, [key["key_alias"] for key in state["keys"].values()])
        if self.bearer() != MASTER_KEY and key_hash(self.bearer()) not in state["keys"]:
            return self.send_json(401, {})
        if path.startswith("/v1/models"):
            return self.send_json(200, {"data": [{"id": model} for model in MODELS]})
        if path.startswith("/model/info"):
            return self.send_json(200, {"data": [{"model_name": model, "model_info": MODEL_INFO} for model in MODELS]})
        if path.startswith("/key/list"):
            return self.list_keys(path)
        if path.startswith("/spend/logs"):
            return self.send_json(200, state["logs"])
        return self.send_json(404, {})

    def list_keys(self, path):
        query = dict(part.split("=", 1) for part in path.split("?", 1)[1].split("&"))
        matching = [dict(key, token=token) for token, key in state["keys"].items()
                    if "key_alias" not in query or key["key_alias"] == query["key_alias"]]
        size, page = int(query.get("size", 10)), int(query.get("page", 1))
        if size > PAGE_LIMIT:
            return self.send_json(400, {"error": "size above the page limit"})
        self.send_json(200, {"keys": matching[(page - 1) * size:page * size], "total_count": len(matching),
                             "current_page": page, "total_pages": max(1, -(-len(matching) // size))})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        body = json.loads(raw or b"{}")
        path = self.path
        if path == "/key/generate":
            state["keys"][key_hash(body["key"])] = {
                "key_alias": body["key_alias"], "max_budget": body["max_budget"],
                "parallel": body["max_parallel_requests"], "spend": 0.0}
            return self.send_json(200, {"key": "not echoed"})
        if path == "/key/delete":
            if "delete_fails" in FAULTS:
                return self.send_json(500, {})
            for token in body["keys"]:
                state["keys"].pop(token, None)
            return self.send_json(200, {})
        if path == "/customer/delete":
            return self.send_json(200, {})
        if path in ("/v1/messages", "/v1/chat/completions"):
            return self.complete(path.endswith("completions"), body)
        return self.send_json(404, {})

    def log_call(self, call_id, token, body, status, spend, prompt, completion, write, read):
        person = body["user"]
        state["logs"].append({
            "request_id": call_id, "api_key": token, "end_user": person, "status": status, "spend": spend,
            "prompt_tokens": prompt, "completion_tokens": completion, "startTime": "2026-01-01T00:00:00",
            "metadata": {"additional_usage_values": {"cache_creation_input_tokens": write, "cache_read_input_tokens": read}}})

    def complete(self, chat, body):
        if chat and "chat_fails" in FAULTS:
            return self.send_json(500, {})
        token = key_hash(self.bearer())
        key = state["keys"].get(token)
        if key is None:
            return self.send_json(401, {})
        if not body.get("user"):
            return self.send_json(401, {})
        max_tokens = body.get("max_tokens", 0)
        with lock:
            state["calls"] += 1
            call_id = "call-%d" % state["calls"]
            header = {"x-litellm-call-id": call_id}
            exhausted = key["spend"] >= key.get("max_budget", 1e9) and not (not chat and "messages_ignores_budget" in FAULTS)
            if exhausted:
                message = "Budget has been exceeded! Current cost: 1, Max budget: 0" if "unnamed_budget_refusal" not in FAULTS else "invalid request"
                self.log_call(call_id, token, body, "failure", 0, 0, 0, 0, 0)
                return self.send_json(400, {"error": {"message": message}}, header)
            refusal = faulty_refusal(body, max_tokens)
            if refusal:
                self.log_call(call_id, token, body, "failure", 0, 0, 0, 0, 0)
                return self.send_json(400, {"error": {"message": refusal}}, header)
            state["inflight"][token] = state["inflight"].get(token, 0) + 1
            if state["inflight"][token] > key.get("parallel", 100):
                state["inflight"][token] -= 1
                self.log_call(call_id, token, body, "failure", 0, 0, 0, 0, 0)
                return self.send_json(429, {}, header)
        try:
            if max_tokens >= 400:
                time.sleep(0.4)
            self.answer(chat, body, key, token, call_id, header)
        finally:
            with lock:
                state["inflight"][token] -= 1

    def bill(self, body, key, token, call_id, system, total, completion):
        cache_key = hashlib.sha256((body["model"] + system[:400]).encode()).hexdigest()
        with lock:
            uncached = "no_cache" in FAULTS
            held = None if uncached else state["cache"].get(cache_key)
            read = 0 if held is None else max(min(held, total) - (20 if "short_read" in FAULTS else 0), 0)
            write = 0 if uncached else total if held is None else total - read
            if not uncached:
                state["cache"][cache_key] = total
            spend = MISS_SPEND if "dear_misses" in FAULTS and total >= MISS_TOKENS and total - read >= MISS_TOKENS else CALL_SPEND
            if "heavy_first_call" in FAULTS and state["answered"] == 0:
                spend = HEAVY_SPEND
            key["spend"] += spend
            state["answered"] += 1
            if not ("drop_row" in FAULTS and state["answered"] == 7):
                self.log_call(call_id, token, body, "success", spend, total, completion, write, read)
        return uncached, write, read

    def answer_body(self, chat, compaction, completion, usage, call=None):
        if chat:
            return {"choices": [{"message": {"role": "assistant", "content": None if call else "ok",
                                             **({"tool_calls": [call]} if call else {}),
                                             **({"content_blocks": [{"type": "compaction"}]} if compaction else {})}}],
                    "usage": usage}
        content = [{"type": "compaction", "content": "summary"}] if compaction else [{"type": "text", "text": "ok"}]
        return {"content": [] if completion == 0 else content, "usage": usage}

    def stream_events(self, chat, compaction, usage):
        if chat:
            return ["data: " + json.dumps({"choices": [{"delta": {"content": "ok"}}]}),
                    "data: " + json.dumps({"choices": [], "usage": usage})]
        return ["data: " + json.dumps({"type": "message_start", "message": {"usage": usage}}),
                *(["data: " + json.dumps({"type": "content_block_start", "content_block": {"type": "compaction"}})] if compaction else []),
                "data: " + json.dumps({"type": "content_block_delta", "delta": {"type": "text_delta", "text": "ok"}})]

    def send_stream(self, lines, header):
        data = ("\n\n".join(lines) + "\n\ndata: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        for name, value in header.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def answer(self, chat, body, key, token, call_id, header):
        system = json.dumps(body.get("system", body.get("messages", [{}])[0]))
        loaded = set() if "reference_ignored" in FAULTS else referenced_names(body)
        billed_tools = [tool for tool in body.get("tools") or [] if not tool.get("defer_loading") or tool_name(tool) in loaded]
        total = max(len(json.dumps([body.get("system"), body.get("messages"), billed_tools])) // 4, 20)
        completion = 0 if body.get("max_tokens") == 0 else min(body.get("max_tokens", 1), 3)
        uncached, write, read = self.bill(body, key, token, call_id, system, total, completion)
        hour = '"ttl": "1h"' in system or '"ttl":"1h"' in system
        usage = {"cache_creation_input_tokens": write, "cache_read_input_tokens": read, "cache_creation": {
            "ephemeral_5m_input_tokens": 0 if hour else write, "ephemeral_1h_input_tokens": write if hour else 0}}
        usage.update(prompt_tokens=total, completion_tokens=completion) if chat else usage.update(input_tokens=total if uncached else 5, output_tokens=completion)
        compaction = "compaction" in body
        if body.get("stream"):
            return self.send_stream(self.stream_events(chat, compaction, usage), header)
        call = None if "reference_ignored" in FAULTS or not chat else loaded_call(body)
        return self.send_json(200, self.answer_body(chat, compaction, completion, usage, call), header)


server = ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
print(server.server_port, flush=True)
server.serve_forever()
