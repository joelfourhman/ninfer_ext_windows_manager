"""Real API smoke tests with explicit TLS trust. Reads a local credential file, never argv keys."""
import argparse
import json
from pathlib import Path
import ssl
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8080")
    parser.add_argument("--key-file", required=True)
    parser.add_argument("--ca-file")
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    key = Path(args.key_file).read_text().strip()
    context = ssl.create_default_context(cafile=args.ca_file) if args.ca_file else ssl.create_default_context()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))

    def request(path, body=None, token=key):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(args.url + path, json.dumps(body).encode() if body is not None else None, headers)
        try:
            with opener.open(req, timeout=1800) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    assert request("/v1/models", token=None)[0] == 401
    assert request("/v1/models", token="invalid")[0] == 401
    status, data = request("/v1/models")
    assert status == 200 and json.loads(data)["data"][0]["id"] == "qwen3.8-27b"
    body = {"model": "qwen3.8-27b", "messages": [{"role": "user", "content": "Reply READY."}],
            "max_tokens": 16, "temperature": 0, "enable_thinking": False}
    status, data = request("/v1/chat/completions", body)
    assert status == 200 and json.loads(data)["choices"][0]["message"]["content"]
    body["stream"] = True
    status, data = request("/v1/chat/completions", body)
    assert status == 200 and b"data:" in data and b"[DONE]" in data
    tools = [{"type": "function", "function": {"name": "lookup_synthetic_source", "description": "Look up a synthetic study", "parameters": {"type": "object", "properties": {"source": {"type": "string"}}, "required": ["source"], "additionalProperties": False}, "strict": True}}]
    body = {"model": "qwen3.8-27b", "messages": [{"role": "user", "content": "Look up source ALPHA."}], "tools": tools,
            "tool_choice": {"type": "function", "function": {"name": "lookup_synthetic_source"}}, "max_tokens": 256, "enable_thinking": False}
    status, data = request("/v1/chat/completions", body)
    assert status == 200, data[:100]
    calls = json.loads(data)["choices"][0]["message"]["tool_calls"]
    assert calls[0]["function"]["name"] == "lookup_synthetic_source"
    assert "source" in json.loads(calls[0]["function"]["arguments"])
    untrusted_rejected = None
    if args.ca_file:
        untrusted = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ssl.create_default_context()))
        try:
            untrusted.open(args.url + "/health", timeout=10)
        except urllib.error.URLError as error:
            untrusted_rejected = isinstance(error.reason, ssl.SSLCertVerificationError)
        assert untrusted_rejected
    report = {"url": args.url, "missingKey": 401, "wrongKey": 401, "discovery": True,
              "inference": True, "sse": True, "strictToolCall": True,
              "tlsVerified": bool(args.ca_file), "untrustedCaRejected": untrusted_rejected}
    Path(args.report).write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
