#!/usr/bin/env python3
"""A data-sharing server for trying WhisperLocal Dev on this Mac.

Speaks the API the app's DataSharingClient uses, keeps what arrives in SQLite,
and shows it at http://127.0.0.1:8787/. Listens on 127.0.0.1 only: no TLS, one
process, no backups. It is a test double and a written-down contract, not the
service.

    python3 scripts/data-sharing-server.py
    python3 scripts/data-sharing-server.py --port 9000 --db /tmp/test.sqlite3

The server holds the line the client promises: a take with any field outside
the schema is refused, so it cannot quietly receive more than the app says it
sends. Tokens are stored as hashes. A take is accepted only under the consent
the server last recorded for that install, and deleting an install removes
its takes and consent records and retires its token.
"""
import argparse
import hashlib
import html
import json
import re
import secrets
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCOPES = {"improve", "train"}
MAX_BODY = 2 * 1024 * 1024
MAX_TAKES = 100
MAX_TEXT = 20_000
TAKES_PER_HOUR = 600

REQUIRED = {
    "id": str, "day": str, "app_version": str, "app_kind": str,
    "stages": list, "raw": str, "polished": str, "redacted": dict,
}
OPTIONAL = {
    "language": str, "speech_model": str, "polish_model": str,
    "context_topics": list, "audio_seconds": (int, float), "cleanup_note": str,
}


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class Refused(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def check_consent(consent, joining=False):
    if not isinstance(consent, dict) or set(consent) != {"version", "scopes", "accepted_at"}:
        raise Refused(400, "consent must be exactly version, scopes, accepted_at")
    scopes = consent["scopes"]
    if not isinstance(consent["version"], str) or not isinstance(scopes, list) \
            or not all(isinstance(s, str) and s in SCOPES for s in scopes):
        raise Refused(400, "unknown consent scope")
    if joining and "improve" not in scopes:
        raise Refused(400, "joining means sharing to improve the app")
    return consent["version"], sorted(set(scopes)), consent["accepted_at"]


def check_take(take):
    if not isinstance(take, dict):
        raise Refused(400, "a take must be an object")
    extra = set(take) - set(REQUIRED) - set(OPTIONAL)
    if extra:
        raise Refused(400, f"fields not in the schema: {sorted(extra)}")
    for name, kind in REQUIRED.items():
        if not isinstance(take.get(name), kind):
            raise Refused(400, f"missing or wrong: {name}")
    for name, kind in OPTIONAL.items():
        if take.get(name) is not None and not isinstance(take[name], kind):
            raise Refused(400, f"wrong: {name}")
    try:
        uuid.UUID(take["id"])
    except ValueError:
        raise Refused(400, "id must be a UUID")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", take["day"]):
        raise Refused(400, "day must be YYYY-MM-DD, no time")
    if len(take["raw"]) > MAX_TEXT or len(take["polished"]) > MAX_TEXT:
        raise Refused(413, "text too long")
    topics = take.get("context_topics") or []
    if len(topics) > 10 or not all(isinstance(t, str) and len(t) <= 200 for t in topics):
        raise Refused(400, "context_topics: at most 10 short strings")
    if len(take["stages"]) > 20 or not all(isinstance(s, str) and len(s) <= 64 for s in take["stages"]):
        raise Refused(400, "stages: at most 20 short strings")
    if not all(isinstance(k, str) and isinstance(v, int) for k, v in take["redacted"].items()):
        raise Refused(400, "redacted: counts by kind")


class Store:
    def __init__(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.Lock()
        self.recent = {}
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS installs (
                id TEXT PRIMARY KEY, token_sha256 TEXT NOT NULL UNIQUE, app_version TEXT,
                created_at TEXT NOT NULL, deleted_at TEXT);
            CREATE TABLE IF NOT EXISTS consents (
                install_id TEXT NOT NULL, version TEXT NOT NULL, scopes TEXT NOT NULL,
                accepted_at TEXT NOT NULL, recorded_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS takes (
                id TEXT NOT NULL, install_id TEXT NOT NULL, received_at TEXT NOT NULL,
                consent_version TEXT NOT NULL, scopes TEXT NOT NULL, payload TEXT NOT NULL,
                PRIMARY KEY (install_id, id));
        """)

    @staticmethod
    def digest(token):
        return hashlib.sha256(token.encode()).hexdigest()

    def install_for(self, header):
        if not header or not header.startswith("Bearer "):
            raise Refused(401, "no token")
        row = self.db.execute(
            "SELECT id FROM installs WHERE token_sha256 = ? AND deleted_at IS NULL",
            (self.digest(header[7:]),)).fetchone()
        if not row:
            raise Refused(401, "unknown or retired token")
        return row["id"]

    def latest_consent(self, install):
        return self.db.execute(
            "SELECT version, scopes FROM consents WHERE install_id = ? ORDER BY rowid DESC LIMIT 1",
            (install,)).fetchone()

    def enroll(self, body):
        version, scopes, accepted = check_consent(body.get("consent"), joining=True)
        install, token = str(uuid.uuid4()), secrets.token_urlsafe(32)
        with self.lock, self.db:
            self.db.execute("INSERT INTO installs VALUES (?, ?, ?, ?, NULL)",
                            (install, self.digest(token), str(body.get("app_version", ""))[:40], now()))
            self.db.execute("INSERT INTO consents VALUES (?, ?, ?, ?, ?)",
                            (install, version, json.dumps(scopes), accepted, now()))
        return 201, {"install_id": install, "token": token}

    def update_consent(self, install, body):
        version, scopes, accepted = check_consent(body)
        with self.lock, self.db:
            self.db.execute("INSERT INTO consents VALUES (?, ?, ?, ?, ?)",
                            (install, version, json.dumps(scopes), accepted, now()))
        return 200, {"ok": True}

    def submit(self, install, body):
        version, scopes, _ = check_consent(body.get("consent"))
        latest = self.latest_consent(install)
        if not latest or latest["version"] != version or json.loads(latest["scopes"]) != scopes:
            raise Refused(409, "consent changed: record it before sending under it")
        if "improve" not in scopes:
            raise Refused(403, "sharing was stopped")
        takes = body.get("takes")
        if not isinstance(takes, list) or not 1 <= len(takes) <= MAX_TAKES:
            raise Refused(400, f"send 1 to {MAX_TAKES} takes")
        for take in takes:
            check_take(take)
        hour_ago = time.time() - 3600
        recent = [t for t in self.recent.get(install, []) if t > hour_ago]
        if len(recent) + len(takes) > TAKES_PER_HOUR:
            raise Refused(429, "too many takes this hour")
        self.recent[install] = recent + [time.time()] * len(takes)
        accepted, duplicates = [], []
        with self.lock, self.db:
            for take in takes:
                cursor = self.db.execute(
                    "INSERT OR IGNORE INTO takes VALUES (?, ?, ?, ?, ?, ?)",
                    (take["id"], install, now(), version, json.dumps(scopes), json.dumps(take, ensure_ascii=False)))
                (accepted if cursor.rowcount else duplicates).append(take["id"])
        return 200, {"accepted": accepted, "duplicates": duplicates}

    def export(self, install):
        row = self.db.execute("SELECT created_at FROM installs WHERE id = ?", (install,)).fetchone()
        consents = [dict(version=c["version"], scopes=json.loads(c["scopes"]), accepted_at=c["accepted_at"],
                         recorded_at=c["recorded_at"])
                    for c in self.db.execute("SELECT * FROM consents WHERE install_id = ? ORDER BY rowid", (install,))]
        takes = [dict(received_at=t["received_at"], consent_version=t["consent_version"],
                      scopes=json.loads(t["scopes"]), take=json.loads(t["payload"]))
                 for t in self.db.execute("SELECT * FROM takes WHERE install_id = ? ORDER BY received_at", (install,))]
        return 200, {"install_id": install, "joined_at": row["created_at"], "consents": consents, "takes": takes}

    def delete(self, install):
        with self.lock, self.db:
            deleted = self.db.execute("DELETE FROM takes WHERE install_id = ?", (install,)).rowcount
            self.db.execute("DELETE FROM consents WHERE install_id = ?", (install,))
            # The token is retired, not kept: nothing left can be reached with it.
            self.db.execute("UPDATE installs SET deleted_at = ?, token_sha256 = ? WHERE id = ?",
                            (now(), "retired-" + secrets.token_hex(16), install))
        self.recent.pop(install, None)
        return 200, {"deleted_takes": deleted}

    def page(self):
        installs = self.db.execute("""
            SELECT i.id, i.app_version, i.created_at, i.deleted_at,
                   (SELECT COUNT(*) FROM takes t WHERE t.install_id = i.id) AS takes,
                   (SELECT scopes FROM consents c WHERE c.install_id = i.id ORDER BY rowid DESC LIMIT 1) AS scopes
            FROM installs i ORDER BY i.created_at DESC""").fetchall()
        takes = self.db.execute("SELECT * FROM takes ORDER BY received_at DESC LIMIT 100").fetchall()
        esc = html.escape
        rows = "".join(
            f"<tr><td><code>{esc(i['id'][:8])}</code></td><td>{esc(i['app_version'] or '')}</td>"
            f"<td>{esc(i['created_at'])}</td><td>{esc(', '.join(json.loads(i['scopes'])) if i['scopes'] else '—')}</td>"
            f"<td>{i['takes']}</td><td>{'deleted ' + esc(i['deleted_at']) if i['deleted_at'] else 'active'}</td></tr>"
            for i in installs) or "<tr><td colspan=6>No installs yet.</td></tr>"
        cards = ""
        for t in takes:
            p = json.loads(t["payload"])
            removed = ", ".join(f"{v} {k}" for k, v in sorted(p["redacted"].items())) or "nothing"
            meta = " · ".join(filter(None, [p["day"], p["app_kind"], p.get("language"), p.get("speech_model"),
                                            p.get("polish_model"), "scopes: " + ", ".join(json.loads(t["scopes"])),
                                            "taken out: " + removed]))
            topics = f"<p class=topics>Auto context: {esc(' · '.join(p['context_topics']))}</p>" if p.get("context_topics") else ""
            cards += (f"<article><p class=meta>{esc(meta)}</p><p class=said>{esc(p['raw'])}</p>"
                      f"<p class=pasted>{esc(p['polished'])}</p>{topics}"
                      f"<p class=meta>install <code>{esc(t['install_id'][:8])}</code> · received {esc(t['received_at'])}</p></article>")
        cards = cards or "<p>No takes yet. Join in WhisperLocal Dev › Settings › Data Sharing, then send a take from the dictation log.</p>"
        return f"""<!doctype html><html><head><meta charset=utf-8><title>Shared Takes</title>
<meta name=viewport content="width=device-width, initial-scale=1">
<style>
:root {{ color-scheme: light dark; --ink:#1c1f26; --muted:#6b7280; --line:#e2e6ee; --panel:#f6f7fa; --accent:#2f7bf0; --bg:#fff; }}
@media (prefers-color-scheme: dark) {{ :root {{ --ink:#e8ebf2; --muted:#98a0b0; --line:#2b3140; --panel:#161a23; --accent:#6aa3ff; --bg:#0f1218; }} }}
body {{ margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 -apple-system, system-ui, sans-serif; }}
main {{ max-width: 980px; margin: 0 auto; padding: 28px 16px 60px; }}
h1 {{ font-size: 24px; margin: 0 0 4px; }} h2 {{ font-size: 15px; text-transform: uppercase; letter-spacing: .08em; color: var(--muted); margin: 28px 0 10px; }}
.lede {{ color: var(--muted); margin: 0; }}
table {{ width:100%; border-collapse: collapse; font-size: 14px; font-variant-numeric: tabular-nums; }}
td, th {{ text-align:left; padding: 8px 10px; border-bottom: 1px solid var(--line); }} th {{ color: var(--muted); font-weight: 600; }}
.wrap {{ overflow-x:auto; }}
article {{ border:1px solid var(--line); border-radius: 12px; padding: 12px 14px; margin: 0 0 10px; background: var(--panel); }}
.meta {{ color: var(--muted); font-size: 13px; margin: 0; }} .said {{ font-family: ui-monospace, Menlo, monospace; font-size: 13px; color: var(--muted); margin: 8px 0 4px; }}
.pasted {{ margin: 0 0 8px; }} .topics {{ font-size: 13px; color: var(--accent); margin: 0 0 6px; }}
a {{ color: var(--accent); }}
</style></head><body><main>
<h1>Shared takes</h1><p class=lede>Local test server for WhisperLocal Dev · {len(takes)} newest takes · <a href="/">Refresh</a></p>
<h2>Installs</h2><div class=wrap><table><tr><th>Install</th><th>App</th><th>Joined</th><th>Consent</th><th>Takes</th><th>State</th></tr>{rows}</table></div>
<h2>Takes</h2>{cards}
</main></body></html>"""


def handler(store):
    class Handler(BaseHTTPRequestHandler):
        server_version = "WhisperLocalDataSharing/0"

        def reply(self, status, body, kind="application/json"):
            data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", kind + "; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def body(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                raise Refused(413, "body too large")
            try:
                return json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                raise Refused(400, "not JSON")

        def route(self):
            path, method = self.path.split("?")[0], self.command
            if method == "GET" and path == "/":
                return 200, store.page()
            if method == "GET" and path == "/health":
                return 200, {"ok": True}
            if method == "POST" and path == "/v1/enroll":
                return store.enroll(self.body())
            install = store.install_for(self.headers.get("Authorization"))
            if method == "POST" and path == "/v1/takes":
                return store.submit(install, self.body())
            if method == "PUT" and path == "/v1/consent":
                return store.update_consent(install, self.body())
            if method == "GET" and path == "/v1/export":
                return store.export(install)
            if method == "DELETE" and path == "/v1/me":
                return store.delete(install)
            raise Refused(404, "no such endpoint")

        def handle_any(self):
            try:
                status, body = self.route()
                self.reply(status, body, "text/html" if isinstance(body, str) else "application/json")
            except Refused as refusal:
                self.reply(refusal.status, {"error": refusal.message})

        do_GET = do_POST = do_PUT = do_DELETE = handle_any

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--db", type=Path, default=ROOT / "dist/data-sharing/dev-server.sqlite3")
    args = parser.parse_args()
    store = Store(args.db)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler(store))
    print(f"data-sharing test server on http://127.0.0.1:{args.port}/ · {args.db}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
