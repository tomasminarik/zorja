"""Serve site/ locally for review, e.g. `python3 tools/serve_site.py` then open
http://localhost:4173.

Pages are sent with caching off. On localhost the place check posts to
`/v1/forecast` here, which this server forwards to the hosted API, so it works before
(and without) the API's CORS for zorja.app. Only for local review; never deployed.
"""

import functools
import http.server
import sys
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.zorja.app/v1/forecast"
ROOT = Path(__file__).resolve().parents[1] / "site"


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_POST(self) -> None:
        if self.path.rstrip("/") != "/v1/forecast":
            self.send_error(404)
            return
        length = min(int(self.headers.get("Content-Length") or 0), 4096)
        request = urllib.request.Request(
            API,
            data=self.rfile.read(length),
            headers={"Content-Type": "application/json", "User-Agent": "Zorja-site-review"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                status, headers, body = response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            status, headers, body = error.code, error.headers, error.read()
        self.send_response(status)
        for name in ("Content-Type", "Retry-After", "X-Request-ID"):
            if headers.get(name):
                self.send_header(name, headers[name])
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass  # keep coordinates out of the terminal


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 4173
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", port), functools.partial(Handler, directory=str(ROOT))
    )
    print(f"zorja.app preview: http://localhost:{port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
