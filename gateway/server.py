"""Small single-owner API boundary. No inference, transcript storage, or compaction here."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import hmac
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import socket
import threading
from urllib.parse import urlsplit, parse_qs
import uuid


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def authenticate(headers, registry, now=None):
    """Read a fresh registry for each request, so revocation needs no engine restart."""
    bearer = headers.get("Authorization", "")
    alternate = headers.get("x-api-key", "")
    token = bearer[7:] if bearer.startswith("Bearer ") else alternate
    if not token or len(token) > 512 or (bearer and alternate and token != alternate):
        return None
    digest = hashlib.sha256(token.encode()).hexdigest()
    now = now or datetime.now(timezone.utc)
    for client in registry.get("clients", []):
        if not hmac.compare_digest(digest, client.get("sha256", "")):
            continue
        if client.get("revokedUtc"):
            return None
        if client.get("expiresUtc") and datetime.fromisoformat(client["expiresUtc"].replace("Z", "+00:00")) <= now:
            return None
        return client["id"]
    return None


def route_allowed(method, path):
    if method == "GET":
        return path in ("/health", "/metrics", "/manager/qwen-profile", "/v1/models") or bool(
            re.fullmatch(r"/v1/(models/[^/]+|responses/[^/]+(?:/input_items)?)", path)
        )
    if method == "POST":
        return path in ("/v1/chat/completions", "/v1/responses", "/v1/responses/input_tokens",
                        "/v1/messages", "/v1/messages/count_tokens")
    return method == "DELETE" and bool(re.fullmatch(r"/v1/responses/[^/]+", path))


def normalize_body(path, payload, policy):
    """Bound generation while preserving tools, thinking, sampling, and protocol semantics."""
    if not isinstance(payload, dict):
        raise ValueError("Request must be a JSON object.")
    if path in ("/v1/chat/completions", "/v1/responses", "/v1/messages"):
        field = "max_output_tokens" if path == "/v1/responses" else "max_tokens"
        if path == "/v1/chat/completions" and "max_completion_tokens" in payload:
            field = "max_completion_tokens"
        payload.setdefault(field, policy["defaultOutputTokens"])
        for name in ("max_tokens", "max_completion_tokens", "max_output_tokens"):
            if name in payload:
                value = payload[name]
                if type(value) is not int or not 0 <= value <= policy["maxOutputTokens"]:
                    raise ValueError(f"{name} must be an integer from 0 to {policy['maxOutputTokens']}.")
    return payload


class Gateway(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, address, config, keys):
        self.config_path = config
        self.keys_path = keys
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "NInferManager/2"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(30)

    def log_message(self, *args):
        # Never log headers, query strings, bodies, or exception strings containing user content.
        pass

    def error(self, status, message, code):
        data = json.dumps({"error": {"message": message, "type": "manager_error", "code": code}}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def do_GET(self):
        self.forward()

    def do_POST(self):
        self.forward()

    def do_DELETE(self):
        self.forward()

    def forward(self):
        request_id = uuid.uuid4().hex
        started = False
        upstream = None
        acquired = False
        try:
            parsed = urlsplit(self.path)
            if parsed.scheme or parsed.netloc or not route_allowed(self.command, parsed.path):
                return self.error(404, "Unsupported endpoint. Compaction is performed by Hermes.", "unsupported_endpoint")
            if any(k.lower() in ("api_key", "apikey", "access_token", "token") for k in parse_qs(parsed.query)):
                return self.error(400, "Send API keys in headers only.", "key_in_url")
            config = read_json(self.server.config_path)
            if parsed.path != "/health":
                try:
                    client = authenticate(self.headers, read_json(self.server.keys_path))
                except (ValueError, OSError, KeyError):
                    return self.error(503, "Authentication registry unavailable.", "auth_unavailable")
                if client is None:
                    return self.error(401, "A valid client API key is required.", "invalid_api_key")
            if self.headers.get("Origin"):
                return self.error(403, "Browser origins are not enabled for this personal API.", "origin_not_allowed")
            if self.headers.get("Transfer-Encoding"):
                return self.error(400, "Use Content-Length for request bodies.", "unsupported_transfer_encoding")
            length_text = self.headers.get("Content-Length", "0")
            if not length_text.isdecimal() or len(self.headers.get_all("Content-Length", [])) > 1:
                return self.error(400, "Invalid Content-Length.", "invalid_length")
            length = int(length_text)
            if length > config.get("maxRequestBytes", 16 * 1024 * 1024):
                return self.error(413, "Request body exceeds the configured limit.", "request_too_large")
            if self.command != "POST" and length:
                return self.error(400, "Request bodies are accepted only for POST.", "unexpected_body")
            if self.command == "POST" and not length:
                return self.error(400, "A JSON body is required.", "missing_body")
            body = self.rfile.read(length) if length else None
            if body is not None:
                if len(body) != length:
                    return self.error(400, "Incomplete request body.", "incomplete_body")
                if self.headers.get_content_type() != "application/json":
                    return self.error(415, "Use application/json.", "invalid_content_type")
                try:
                    body = json.dumps(normalize_body(parsed.path, json.loads(body), config["qwen"]), ensure_ascii=False).encode()
                except (ValueError, UnicodeError) as error:
                    return self.error(400, str(error) if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError) else "Invalid JSON.", "invalid_request")
            if parsed.path == "/manager/qwen-profile":
                data = json.dumps(config["qwen"]).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                return self.wfile.write(data)
            acquired = self.server.slots.acquire(blocking=False)
            if not acquired:
                return self.error(429, "Qwen server queue is full. Retry later.", "queue_full")
            upstream = HTTPConnection(config["backendHost"], config["backendPort"], timeout=config.get("backendTimeoutSeconds", 1800))
            headers = {"Authorization": "Bearer " + config["backendKey"], "Content-Type": "application/json",
                       "Connection": "close", "x-request-id": request_id}
            for name in ("anthropic-version", "anthropic-beta"):
                if self.headers.get(name):
                    headers[name] = self.headers[name]
            upstream.request(self.command, self.path, body=body, headers=headers)
            response = upstream.getresponse()
            self.send_response(response.status)
            for name in ("Content-Type", "request-id", "x-request-id", "Retry-After"):
                if response.getheader(name):
                    self.send_header(name, response.getheader(name))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            started = True
            while chunk := response.read1(65536):
                self.wfile.write(f"{len(chunk):X}\r\n".encode() + chunk + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, socket.timeout):
            self.close_connection = True
        except Exception:
            if not started:
                self.error(502, "The local inference service is unavailable. Run Diagnostics.", "backend_unavailable")
            else:
                self.close_connection = True
        finally:
            if upstream:
                upstream.close()
            if acquired:
                self.server.slots.release()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--keys", required=True)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    read_json(args.config)
    read_json(args.keys)
    print("NInfer Manager gateway ready; credentials and request bodies are never logged.", flush=True)
    Gateway((args.host, args.port), args.config, args.keys).serve_forever()


if __name__ == "__main__":
    main()
