#!/usr/bin/env python3
"""Receive debug.txt POSTs from a ComputerCraft turtle.

Usage (on your PC):
  python receive_debug.py

Then on the turtle (after allowing local HTTP — see below):
  update_miner
  # ensure debug_server.txt exists (written by update_miner, or create it):
  #   http://127.0.0.1:8787/debug
  lua
  require("turtle_lib").upload_debug()

CC:Tweaked blocks private IPs by default. In your world folder edit:
  serverconfig/computercraft-server.toml

Add ABOVE the `$private` deny rule (order matters — first match wins):
  [[http.rules]]
      host = "127.0.0.1"
      port = 8787
      action = "allow"

Restart Minecraft after changing that config.
"""

from __future__ import annotations

import datetime as dt
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = "127.0.0.1"
PORT = 8787
OUT_DIR = Path(__file__).resolve().parent


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        print(f"[{dt.datetime.now():%H:%M:%S}] " + (fmt % args))

    def do_GET(self) -> None:
        body = (
            b"debug receiver ok\n"
            b"POST raw debug.txt to /debug\n"
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(length)
        stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
        out = OUT_DIR / f"debug_from_turtle_{stamp}.txt"
        out.write_bytes(data)

        # Also refresh a stable name for quick open.
        latest = OUT_DIR / "debug_from_turtle.txt"
        latest.write_bytes(data)

        msg = f"saved {out.name} ({len(data)} bytes)\n".encode()
        print(f"Received debug log -> {out} ({len(data)} bytes)")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(msg)))
        self.end_headers()
        self.wfile.write(msg)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Listening on http://{HOST}:{PORT}/debug")
    print(f"Saving uploads into: {OUT_DIR}")
    print("Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
