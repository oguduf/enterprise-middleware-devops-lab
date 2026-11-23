import json
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "health-check.py"


class HealthHandler(BaseHTTPRequestHandler):
    status_code = 200
    payload = {"status": "UP"}
    calls = 0

    def do_GET(self):
        type(self).calls += 1
        data = json.dumps(type(self).payload).encode("utf-8")
        self.send_response(type(self).status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):
        pass


class HealthCheckTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), HealthHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/health"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def run_check(self, *extra):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--url", self.url, "--timeout", "1", "--interval", "0", *extra],
            text=True,
            capture_output=True,
            check=False,
        )

    def setUp(self):
        HealthHandler.status_code = 200
        HealthHandler.payload = {"status": "UP"}
        HealthHandler.calls = 0

    def test_up_response_succeeds(self):
        result = self.run_check("--attempts", "1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("health check passed", result.stdout)

    def test_non_up_payload_fails(self):
        HealthHandler.payload = {"status": "DOWN"}
        result = self.run_check("--attempts", "1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("status was not UP", result.stdout)

    def test_http_error_retries_then_fails(self):
        HealthHandler.status_code = 503
        result = self.run_check("--attempts", "2")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(HealthHandler.calls, 2)
        self.assertIn("HTTP 503", result.stdout)

    def test_embedded_credentials_are_rejected(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--url", "http://user:secret@example.invalid/health"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("no embedded credentials", result.stderr)


if __name__ == "__main__":
    unittest.main()
