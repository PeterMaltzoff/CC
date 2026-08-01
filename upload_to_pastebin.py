#!/usr/bin/env python3
"""
Push local turtle scripts to Pastebin.

Recommended (keeps paste IDs unchanged):
  python upload_to_pastebin.py
  python upload_to_pastebin.py --manual

For each file: copies content to clipboard and opens the Pastebin edit page.
Log in on the site, select all, paste, save. Same URL as before — no turtle changes.

API mode (creates NEW pastes — IDs change, not recommended):
  python upload_to_pastebin.py --api

Requires PASTEBIN_API_KEY plus login via username/password (see doc_api#9).
The old api_user_key.html page no longer exists.
"""

import argparse
import os
import re
import subprocess
import sys
import webbrowser
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

API_POST = "https://pastebin.com/api/api_post.php"
API_LOGIN = "https://pastebin.com/api/api_login.php"
USER_AGENT = "ComputerCraft-uploader/1.0"

PASTES = [
    {"key": "kuPwViZS", "file": "turtle_lib.lua", "name": "Turtle Lib"},
    {"key": "yHmi8WhL", "file": "strip_miner.lua", "name": "Strip Miner"},
]

ROOT = Path(__file__).resolve().parent
UPDATE_MINER = ROOT / "update_miner.lua"


def copy_to_clipboard(text: str) -> bool:
    """Copy text to the system clipboard (Windows)."""
    try:
        subprocess.run(
            ["clip"],
            input=text.encode("utf-16le"),
            check=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        return True
    except (FileNotFoundError, subprocess.CalledProcessError, OSError):
        return False


def read_secret(env_name: str, filename: str) -> str:
    value = os.environ.get(env_name, "").strip()
    if value:
        return value

    path = ROOT / filename
    if path.exists():
        return path.read_text(encoding="utf-8").strip()

    return ""


def api_request(url: str, fields: dict) -> str:
    data = urlencode(fields).encode("utf-8")
    req = Request(
        url,
        data=data,
        method="POST",
        headers={
            "User-Agent": USER_AGENT,
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )

    try:
        with urlopen(req, timeout=30) as resp:
            return resp.read().decode("utf-8").strip()
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"HTTP {exc.code}: {body or exc.reason}") from exc
    except URLError as exc:
        raise RuntimeError(f"Network error: {exc.reason}") from exc


def load_dev_key() -> str:
    key = read_secret("PASTEBIN_API_KEY", ".pastebin_key")
    if not key:
        print("Missing Pastebin dev key.", file=sys.stderr)
        print("Set PASTEBIN_API_KEY or create .pastebin_key", file=sys.stderr)
        sys.exit(1)
    return key


def login_user_key(dev_key: str, username: str, password: str) -> str:
    body = api_request(
        API_LOGIN,
        {
            "api_dev_key": dev_key,
            "api_user_name": username,
            "api_user_password": password,
        },
    )
    if body.startswith("Bad API request"):
        raise RuntimeError(body)
    return body


def load_user_key(dev_key: str) -> str:
    key = read_secret("PASTEBIN_USER_KEY", ".pastebin_user_key")
    if key:
        return key

    username = os.environ.get("PASTEBIN_USERNAME", "").strip()
    password = os.environ.get("PASTEBIN_PASSWORD", "").strip()
    if not username or not password:
        print("Missing Pastebin login for --api mode.", file=sys.stderr)
        print("", file=sys.stderr)
        print("Log in via the API (doc section 9):", file=sys.stderr)
        print("  https://pastebin.com/doc_api#9", file=sys.stderr)
        print("", file=sys.stderr)
        print("  export PASTEBIN_USERNAME=your_username", file=sys.stderr)
        print("  export PASTEBIN_PASSWORD=your_password", file=sys.stderr)
        print("", file=sys.stderr)
        print("Or save a cached user key to .pastebin_user_key", file=sys.stderr)
        print("(returned by the login call above).", file=sys.stderr)
        sys.exit(1)

    key = login_user_key(dev_key, username, password)
    cache = ROOT / ".pastebin_user_key"
    cache.write_text(key + "\n", encoding="utf-8")
    print(f"Cached user key to {cache.name}\n")
    return key


def delete_paste(dev_key: str, user_key: str, paste_key: str) -> None:
    body = api_request(
        API_POST,
        {
            "api_dev_key": dev_key,
            "api_user_key": user_key,
            "api_option": "delete",
            "api_paste_key": paste_key,
        },
    )
    if body.startswith("Bad API request"):
        print(f"  (delete skipped: {body})")
    else:
        print(f"  deleted old paste {paste_key}")


def create_paste(dev_key: str, user_key: str, content: str, title: str) -> str:
    body = api_request(
        API_POST,
        {
            "api_dev_key": dev_key,
            "api_user_key": user_key,
            "api_option": "paste",
            "api_paste_code": content,
            "api_paste_name": title,
            "api_paste_format": "lua",
            "api_paste_private": "0",
            "api_paste_expire_date": "N",
        },
    )
    if body.startswith("Bad API request"):
        raise RuntimeError(body)
    if not body.startswith("https://pastebin.com/"):
        raise RuntimeError(f"Unexpected response: {body}")

    return body.rsplit("/", 1)[-1]


def patch_update_miner(old_key: str, new_key: str) -> None:
    if old_key == new_key or not UPDATE_MINER.exists():
        return

    text = UPDATE_MINER.read_text(encoding="utf-8")
    updated, count = re.subn(
        rf'id = "{re.escape(old_key)}"',
        f'id = "{new_key}"',
        text,
    )
    if count:
        UPDATE_MINER.write_text(updated, encoding="utf-8")
        print(f"  updated {UPDATE_MINER.name}: {old_key} -> {new_key}")


def patch_self_config(old_key: str, new_key: str) -> None:
    if old_key == new_key:
        return

    path = Path(__file__)
    text = path.read_text(encoding="utf-8")
    updated = text.replace(f'"key": "{old_key}"', f'"key": "{new_key}"', 1)
    if updated != text:
        path.write_text(updated, encoding="utf-8")


def run_manual() -> None:
    print("Manual upload (paste IDs stay the same)\n")
    print("Make sure you are logged in to Pastebin in your browser.\n")

    for i, entry in enumerate(PASTES, start=1):
        path = ROOT / entry["file"]
        if not path.exists():
            print(f"SKIP: {entry['file']} not found\n")
            continue

        content = path.read_text(encoding="utf-8")
        edit_url = f"https://pastebin.com/edit/{entry['key']}"

        print(f"[{i}/{len(PASTES)}] {entry['name']} ({entry['file']})")
        print(f"  Edit: {edit_url}")

        if copy_to_clipboard(content):
            print("  Copied to clipboard.")
        else:
            print("  Could not copy to clipboard — open the file manually.")

        webbrowser.open(edit_url)
        print("  Browser opened. Select all in the editor, paste, save.")

        if i < len(PASTES):
            try:
                input("  Press Enter when done, for the next file...")
            except EOFError:
                print()
        print()

    print("Done. On the turtle run: update_miner.lua")


def run_api() -> None:
    dev_key = load_dev_key()
    user_key = load_user_key(dev_key)

    print("API upload (delete + create — paste IDs WILL change)\n")
    id_changed = False

    for entry in PASTES:
        path = ROOT / entry["file"]
        if not path.exists():
            print(f"SKIP: {entry['file']} not found\n", file=sys.stderr)
            continue

        old_key = entry["key"]
        print(f"{entry['name']} ({entry['file']})")
        delete_paste(dev_key, user_key, old_key)

        content = path.read_text(encoding="utf-8")
        new_key = create_paste(dev_key, user_key, content, entry["name"])
        print(f"  OK -> https://pastebin.com/{new_key}")

        if new_key != old_key:
            id_changed = True
            patch_update_miner(old_key, new_key)
            patch_self_config(old_key, new_key)

        print()

    print("Done.")
    if id_changed:
        print("Paste IDs changed — copy update_miner.lua to the turtle before running it.")
    else:
        print("On the turtle run: update_miner.lua")


def main() -> None:
    parser = argparse.ArgumentParser(description="Upload turtle scripts to Pastebin.")
    parser.add_argument(
        "--api",
        action="store_true",
        help="Use Pastebin API (creates new pastes; IDs change). Default is manual edit.",
    )
    parser.add_argument(
        "--manual",
        action="store_true",
        help="Open edit pages and copy to clipboard (default).",
    )
    args = parser.parse_args()

    if args.api:
        run_api()
    else:
        run_manual()


if __name__ == "__main__":
    main()
