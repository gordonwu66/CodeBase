#!/usr/bin/env python3
"""
CodeBase AI companion service — Phase 3 scaffold.

Plumbing only (no real AI yet). It proves the end-to-end loop:

  1. Gitea POSTs an event to OUR endpoint:   POST /gitea/events
  2. We verify the webhook HMAC signature.
  3. On a pull_request event we fetch the PR diff via the bot token.
  4. We act back on the PR: post a comment + set a commit status.

Everything is stdlib (http.server, urllib, hmac) so the image stays tiny and dependency-free.
Replace the `review_pull_request` body with a real model call in a later phase.
"""
import hashlib
import hmac
import json
import logging
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# --- Config (all from env; see deploy/.env) ---
PORT = int(os.environ.get("PORT", "8080"))
GITEA_API_URL = os.environ.get("GITEA_API_URL", "http://gitea:3000/api/v1").rstrip("/")
GITEA_BOT_TOKEN = os.environ.get("GITEA_BOT_TOKEN", "")
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")
# Context label this service reports as a commit status (its attributable identity).
STATUS_CONTEXT = os.environ.get("STATUS_CONTEXT", "codebase-ai/review")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("codebase-ai")


# --- Gitea REST helpers (we are the CLIENT here, authenticating as the bot) ---
def gitea_request(method: str, path: str, body=None, accept="application/json"):
    url = f"{GITEA_API_URL}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"token {GITEA_BOT_TOKEN}")
    req.add_header("Accept", accept)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read()
            if accept == "application/json" and raw:
                return resp.status, json.loads(raw)
            return resp.status, raw.decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def get_pr_diff(owner: str, repo: str, index: int) -> str:
    status, body = gitea_request(
        "GET", f"/repos/{owner}/{repo}/pulls/{index}.diff", accept="text/plain"
    )
    return body if status == 200 else ""


def post_pr_comment(owner: str, repo: str, index: int, markdown: str):
    return gitea_request(
        "POST", f"/repos/{owner}/{repo}/issues/{index}/comments", body={"body": markdown}
    )


def set_commit_status(owner: str, repo: str, sha: str, state: str, description: str):
    return gitea_request(
        "POST",
        f"/repos/{owner}/{repo}/statuses/{sha}",
        body={"state": state, "context": STATUS_CONTEXT, "description": description},
    )


# --- The "review" — a placeholder for a real model call ---
def review_pull_request(diff: str) -> dict:
    """
    TODO (Phase 3+): send `diff` (and richer context from the Phase 4 context service)
    to a model and return structured findings. For now we compute a trivial summary so
    the loop is observable without any AI dependency.
    """
    added = sum(1 for line in diff.splitlines() if line.startswith("+") and not line.startswith("+++"))
    removed = sum(1 for line in diff.splitlines() if line.startswith("-") and not line.startswith("---"))
    files = sum(1 for line in diff.splitlines() if line.startswith("diff --git"))
    summary = (
        f"**CodeBase AI (scaffold)** reviewed this PR.\n\n"
        f"- files changed: `{files}`\n- lines added: `{added}`\n- lines removed: `{removed}`\n\n"
        f"_No real analysis yet — this is the Phase 3 plumbing. A model call goes here._"
    )
    return {"summary": summary, "state": "success", "description": f"{files} file(s), +{added}/-{removed}"}


def handle_pull_request(payload: dict):
    action = payload.get("action")
    if action not in ("opened", "reopened", "synchronized", "synchronize"):
        log.info("pull_request action=%s ignored", action)
        return
    repo = payload["repository"]
    owner, name = repo["owner"]["login"], repo["name"]
    pr = payload["pull_request"]
    index = pr["number"]
    sha = pr["head"]["sha"]
    log.info("reviewing PR %s/%s#%s (sha=%s)", owner, name, index, sha[:8])

    diff = get_pr_diff(owner, name, index)
    result = review_pull_request(diff)

    code, _ = post_pr_comment(owner, name, index, result["summary"])
    log.info("posted comment -> HTTP %s", code)
    code, _ = set_commit_status(owner, name, sha, result["state"], result["description"])
    log.info("set commit status %s -> HTTP %s", STATUS_CONTEXT, code)


# --- Webhook authenticity ---
def signature_ok(body: bytes, sig_hex: str) -> bool:
    if not WEBHOOK_SECRET:
        log.warning("WEBHOOK_SECRET not set — skipping signature verification (DO NOT do this in prod)")
        return True
    if not sig_hex:
        return False
    expected = hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, sig_hex)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, obj: dict):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"status": "ok", "service": "codebase-ai"})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/gitea/events":
            return self._send(404, {"error": "not found"})

        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        event = self.headers.get("X-Gitea-Event", "")
        sig = self.headers.get("X-Gitea-Signature", "")

        if not signature_ok(body, sig):
            log.warning("rejected event=%s: bad signature", event)
            return self._send(401, {"error": "invalid signature"})

        # Respond 2xx fast; for a scaffold we process inline. Move to a queue/worker later
        # so a slow model call never trips Gitea's webhook delivery timeout.
        try:
            payload = json.loads(body) if body else {}
        except json.JSONDecodeError:
            return self._send(400, {"error": "invalid json"})

        log.info("received event=%s action=%s", event, payload.get("action"))
        if event == "pull_request":
            try:
                handle_pull_request(payload)
            except Exception:  # never 500 the webhook over a processing error
                log.exception("error handling pull_request")
        else:
            log.info("event=%s ignored (no handler)", event)

        self._send(202, {"status": "accepted", "event": event})

    def log_message(self, *args):  # quiet the default noisy logger; we log our own
        pass


def main():
    if not GITEA_BOT_TOKEN:
        log.warning("GITEA_BOT_TOKEN not set — callbacks to Gitea will 401")
    log.info("CodeBase AI service listening on :%s  (api=%s)", PORT, GITEA_API_URL)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
