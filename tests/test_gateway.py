"""Observable HTTP-boundary tests; no Docker, GPU, or external packages required."""
from datetime import datetime, timedelta, timezone
import hashlib
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
import socket
from pathlib import Path
import tempfile
import threading
import time
import unittest

spec = importlib.util.spec_from_file_location("manager_gateway", Path(__file__).resolve().parents[1] / "gateway/server.py")
gw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gw)
TOKEN = "nwm_test_" + "a" * 64


class Backend(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    seen = []
    cancelled = threading.Event()

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/health":
            result = b'{"status":"ok"}'
        else:
            result = b'{"data":[{"id":"qwen3.8-27b"}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(result)))
        self.end_headers()
        self.wfile.write(result)

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.seen.append((self.headers.get("Authorization"), payload))
        if payload.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b'data: {"first":true}\n\n')
            self.wfile.flush()
            if payload.get("cancelProbe"):
                for _ in range(100):
                    time.sleep(0.03)
                    try:
                        self.wfile.write(b'data: {"progress":true}\n\n')
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                        self.cancelled.set()
                        break
                self.close_connection = True
                return
            time.sleep(0.4)
            try:
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                self.cancelled.set()
            self.close_connection = True
        else:
            result = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(result)))
            self.end_headers()
            self.wfile.write(result)


class GatewayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = Path(__file__).resolve().parents[1] / "temp"
        scratch.mkdir(exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory(dir=scratch)
        cls.directory = Path(cls.temp.name)
        cls.backend = ThreadingHTTPServer(("127.0.0.1", 0), Backend)
        threading.Thread(target=cls.backend.serve_forever, daemon=True).start()
        cls.config = cls.directory / "gateway.json"
        cls.config.write_text(json.dumps({"backendHost": "127.0.0.1", "backendPort": cls.backend.server_port,
            "backendKey": "backend-only", "qwen": {"defaultOutputTokens": 8192, "maxOutputTokens": 16384}, "maxRequestBytes": 2048}))
        cls.keys = cls.directory / "clients.json"
        cls.gateway = gw.Gateway(("127.0.0.1", 0), cls.config, cls.keys)
        threading.Thread(target=cls.gateway.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.gateway.shutdown(); cls.gateway.server_close()
        cls.backend.shutdown(); cls.backend.server_close()
        cls.temp.cleanup()

    def setUp(self):
        self.registry = {"clients": [{"id": "test", "sha256": hashlib.sha256(TOKEN.encode()).hexdigest(), "revokedUtc": None, "expiresUtc": None}]}
        self.save_registry()

    def save_registry(self):
        temporary = self.keys.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.registry))
        os.replace(temporary, self.keys)

    def request(self, path="/v1/models", method="GET", body=None, token=TOKEN, headers=None):
        conn = HTTPConnection("127.0.0.1", self.gateway.server_port, timeout=3)
        request_headers = {"Content-Type": "application/json"}
        if token is not None:
            request_headers["Authorization"] = "Bearer " + token
        request_headers.update(headers or {})
        conn.request(method, path, body=json.dumps(body).encode() if body is not None else None, headers=request_headers)
        response = conn.getresponse(); content = response.read(); conn.close()
        return response.status, json.loads(content)

    def test_missing_and_wrong_key_fail(self):
        for token in (None, "wrong"):
            self.assertEqual(self.request(token=token)[0], 401)

    def test_model_policy_requires_auth_and_never_exposes_backend_credentials(self):
        self.assertEqual(self.request("/manager/qwen-profile", token=None)[0], 401)
        status, policy = self.request("/manager/qwen-profile")
        self.assertEqual(status, 200)
        self.assertEqual(policy["defaultOutputTokens"], 8192)
        self.assertNotIn("backend-only", json.dumps(policy))

    def test_model_policy_rejects_invalid_framing(self):
        self.assertEqual(self.request("/manager/qwen-profile", headers={"Transfer-Encoding": "chunked"})[0], 400)
        self.assertEqual(self.request("/manager/qwen-profile", body={"ignored": True})[0], 400)
        self.assertEqual(self.request("/health", body={}, token=None)[0], 400)

    def test_health_is_minimal_and_public(self):
        self.assertEqual(self.request("/health", token=None), (200, {"status": "ok"}))

    def test_valid_key_and_anthropic_key_header(self):
        self.assertEqual(self.request()[0], 200)
        self.assertEqual(self.request(token=None, headers={"x-api-key": TOKEN})[0], 200)

    def test_atomic_revocation_is_immediate(self):
        self.assertEqual(self.request()[0], 200)
        self.registry["clients"][0]["revokedUtc"] = datetime.now(timezone.utc).isoformat()
        self.save_registry()
        self.assertEqual(self.request()[0], 401)

    def test_expired_key_fails(self):
        self.registry["clients"][0]["expiresUtc"] = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
        self.save_registry()
        self.assertEqual(self.request()[0], 401)

    def test_unreadable_registry_fails_closed(self):
        self.keys.write_text("{")
        self.assertEqual(self.request()[0], 503)

    def test_backend_key_replaces_client_key(self):
        body = {"model": "qwen3.8-27b", "messages": [{"role": "user", "content": "hello"}], "tools": [{"type": "function"}]}
        status, echoed = self.request("/v1/chat/completions", "POST", body)
        self.assertEqual(status, 200)
        self.assertEqual(Backend.seen[-1][0], "Bearer backend-only")
        self.assertEqual(echoed["messages"], body["messages"])
        self.assertEqual(echoed["tools"], body["tools"])
        self.assertEqual(echoed["max_tokens"], 8192)

    def test_excess_output_or_invalid_type_is_rejected(self):
        for value in (20000, -1, True, "8192"):
            self.assertEqual(self.request("/v1/chat/completions", "POST", {"max_tokens": value})[0], 400)

    def test_body_size_is_bounded(self):
        self.assertEqual(self.request("/v1/chat/completions", "POST", {"messages": "x" * 3000})[0], 413)

    def test_browser_origin_and_key_in_url_rejected(self):
        self.assertEqual(self.request(headers={"Origin": "https://untrusted.example"})[0], 403)
        self.assertEqual(self.request("/v1/models?api_key=secret")[0], 400)

    def test_unsupported_compaction_and_absolute_url(self):
        self.assertEqual(self.request("/v1/responses/compact", "POST", {})[0], 404)
        self.assertEqual(self.request("http://untrusted.example/v1/models")[0], 404)

    def test_sse_first_event_is_forwarded_before_completion(self):
        conn = HTTPConnection("127.0.0.1", self.gateway.server_port, timeout=3)
        conn.request("POST", "/v1/chat/completions", json.dumps({"stream": True}), {"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
        response = conn.getresponse()
        started = time.monotonic()
        first = response.readline()
        self.assertIn(b'"first":true', first)
        self.assertLess(time.monotonic() - started, 0.3)
        self.assertIn(b"[DONE]", response.read())
        conn.close()

    def test_client_disconnect_closes_upstream_stream(self):
        Backend.cancelled.clear()
        conn = HTTPConnection("127.0.0.1", self.gateway.server_port, timeout=3)
        conn.request("POST", "/v1/chat/completions", json.dumps({"stream": True, "cancelProbe": True}),
            {"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
        response = conn.getresponse()
        self.assertIn(b"first", response.readline())
        conn.sock.shutdown(socket.SHUT_RDWR)
        response.close(); conn.close()
        self.assertTrue(Backend.cancelled.wait(3), "Proxy did not close the upstream response on disconnect")


if __name__ == "__main__":
    unittest.main()
