#!/usr/bin/env python3
"""Receive debug.txt POSTs from a ComputerCraft turtle.

Usage (on your PC):
  python receive_debug.py

On the turtle:
  upload_debug
  # or automatic at end of strip_miner when DEBUG=true

CC:Tweaked blocks private IPs by default. Allow 127.0.0.1:8787 above the
$private deny rule in world/serverconfig/computercraft-server.toml, then
restart Minecraft.
"""

from __future__ import annotations

import datetime as dt
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = "127.0.0.1"
PORT = 8787
OUT_DIR = Path(__file__).resolve().parent
OUT_FILE = OUT_DIR / "debug_from_turtle.txt"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        print(f"[{dt.datetime.now():%H:%M:%S}] " + (fmt % args))

    def do_GET(self) -> None:
        body = b"debug receiver ok\nPOST raw debug.txt to /debug\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(length)
        OUT_FILE.write_bytes(data)

        msg = f"saved {OUT_FILE.name} ({len(data)} bytes)\n".encode()
        print(f"Received debug log -> {OUT_FILE} ({len(data)} bytes)")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(msg)))
        self.end_headers()
        self.wfile.write(msg)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Listening on http://{HOST}:{PORT}/debug")
    print(f"Writing to: {OUT_FILE}")
    print("Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
