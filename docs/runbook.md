# CodeBase Operations Runbook — Phases 1–3 (Forge + CI + AI companion)

Operational reference for the self-hosted Gitea deployment defined in `deploy/`.
Stack: **Gitea** (SQLite) behind **Caddy** (automatic HTTPS), a **Gitea Actions runner**, and
an **AI companion service** (webhook consumer), via Docker Compose.

> Design intent: stay as close to upstream Gitea as possible (see
> [`design-doc.md`](./design-doc.md) → *Customization Strategy*). All Gitea config is set
> through `GITEA__section__KEY` env vars so the generated `app.ini` stays upgrade-safe.

---

## 1. Topology

| Service | Image | Role | Host ports |
|---|---|---|---|
| `gitea` | `gitea/gitea:1.22.6` | Git hosting, PRs, API, webhooks, built-in SSH | `2222 → 22` (SSH) |
| `caddy` | `caddy:2.8` | TLS termination + reverse proxy to `gitea:3000` | `80`, `443` |
| `runner` | `gitea/act_runner:0.2.11` | Gitea Actions CI runner (executes workflows) | none (outbound only) |
| `ai-service` | `codebase/ai-service:0.1.0` (built) | Webhook consumer + Gitea API client (bot) | none (internal only) |

Persistent volumes (named, survive `docker compose down`):
- `codebase-gitea-data` → `/data` (DB, repositories, LFS, config, avatars)
- `codebase-caddy-data` → issued TLS certs / ACME account state
- `codebase-caddy-config` → Caddy autosave config
- `codebase-runner-data` → runner identity (`.runner`) so it doesn't re-register on restart

Gitea HTTP (`3000`) is **not** published to the host — all web traffic goes through Caddy.

---

## 2. First-time setup

```bash
cd deploy
cp .env.example .env

# Generate the two secrets and paste them into .env:
docker run --rm gitea/gitea:1.22.6 gitea generate secret SECRET_KEY
docker run --rm gitea/gitea:1.22.6 gitea generate secret INTERNAL_TOKEN

# Edit .env: set GITEA_DOMAIN, CADDY_TLS (email for public ACME, or "internal" locally).
docker compose up -d
docker compose ps        # both services should report healthy/running
```

Then bootstrap the admin user, org/team/pilot repo, and branch protection:

```bash
ADMIN_PASSWORD='choose-a-strong-password' GITEA_DOMAIN="$(grep ^GITEA_DOMAIN .env | cut -d= -f2)" \
  ./scripts/bootstrap.sh
```

The script prints a one-time `bootstrap` API token; store it in your secret manager and
**revoke it in the UI once provisioning is done**.

### Local prototype (no public domain)
Set `GITEA_DOMAIN=gitea.localhost` and `CADDY_TLS=internal`. `*.localhost` resolves to
`127.0.0.1`. Trust Caddy's local CA to avoid browser warnings:
```bash
docker compose exec caddy caddy trust   # or import caddy-data .../authorities/local/root.crt
```

---

## 3. Acceptance checks (Phase 1 exit criteria)

| Criterion | How to verify |
|---|---|
| Gitea reachable via HTTPS | `curl -fsS https://$GITEA_DOMAIN/api/healthz` returns `200` |
| At least one real repo hosted & usable | clone/push/pull the pilot repo (below) |
| Branch protection enabled on pilot | UI → repo → Settings → Branches shows `main` protected; direct push to `main` is rejected |
| Deployment/runbook docs exist | this file + `deploy/` |

**Clone / push / pull validation:**
```bash
# HTTPS
git clone https://$GITEA_DOMAIN/codebase/pilot.git
# SSH (add your key in UI → Settings → SSH Keys first)
git clone ssh://git@$GITEA_DOMAIN:2222/codebase/pilot.git

cd pilot
git checkout -b feature/smoke
echo "hello" >> README.md && git commit -am "smoke test"
git push -u origin feature/smoke      # succeeds (feature branch)
# Open a PR in the UI; merging requires 1 approval + the ci/gitea-actions check (Phase 2).
git push origin feature/smoke:main    # MUST be rejected by branch protection
```

---

## 4. Day-to-day operations

| Action | Command (run from `deploy/`) |
|---|---|
| **Startup** | `docker compose up -d` |
| **Shutdown** (keep data) | `docker compose down` |
| **Restart one service** | `docker compose restart gitea` |
| **Logs (follow)** | `docker compose logs -f gitea` / `... caddy` |
| **Status / health** | `docker compose ps` |
| **Open a shell** | `docker compose exec -u git gitea bash` |
| **Gitea admin CLI** | `docker compose exec -u git gitea gitea admin --help` |

`docker compose down -v` also deletes the named volumes — **never** run it on a live
instance without a verified backup.

---

## 5. Backup & restore

**Backup** (consistent dump of DB + repos + LFS + config):
```bash
./scripts/backup.sh                       # writes deploy/backups/gitea-dump-<UTC>.zip
```
Schedule it (host cron example, daily 02:00):
```
0 2 * * * cd /opt/codebase/deploy && ./scripts/backup.sh >> /var/log/codebase-backup.log 2>&1
```
Also snapshot the `codebase-caddy-data` volume periodically so re-issuing certs after a
restore doesn't hit Let's Encrypt rate limits (command printed by `backup.sh`).

**Restore** (overwrites the instance — stop traffic first):
```bash
docker compose stop gitea
./scripts/restore.sh ./backups/gitea-dump-<stamp>.zip   # prints the guided manual steps
```
`gitea dump` has no single restore command; the script walks you through unpacking the
archive, placing the SQLite DB / `repositories` / `data` / `app.ini` into the volume,
fixing ownership to `1000:1000`, then `docker compose start gitea`.

Test a restore into a throwaway stack at least once before you rely on it.

---

## 6. Upgrades

Gitea supports in-place minor/patch upgrades; **back up first** and read the release notes.
```bash
./scripts/backup.sh
# Bump the image tag in docker-compose.yml (e.g. 1.22.6 -> 1.22.x), then:
docker compose pull gitea
docker compose up -d gitea            # runs DB migrations on start
docker compose logs -f gitea          # watch for "Migration ... done" and a clean boot
```
- Move one minor version at a time; don't skip across majors.
- Upgrade Caddy the same way (`caddy` service tag) — it's stateless aside from its volumes.

## 7. Rollback

```bash
# 1. Stop the bad version
docker compose stop gitea
# 2. Restore the pre-upgrade backup (Section 5) so the DB schema matches the old binary —
#    a newer schema will NOT run on an older Gitea.
./scripts/restore.sh ./backups/gitea-dump-<pre-upgrade-stamp>.zip
# 3. Pin docker-compose.yml back to the previous image tag, then:
docker compose up -d gitea
docker compose logs -f gitea
```
Rule of thumb: a rollback of the binary **requires** restoring the matching pre-migration
backup. This is the main reason backup.sh runs before every upgrade.

---

## 8. Postgres migration assumptions (recorded for later)

SQLite is intentional for prototype speed. When moving to Postgres (likely production path):
- Add a `postgres` service + volume; set `GITEA__database__DB_TYPE=postgres` and the
  `HOST/NAME/USER/PASSWD` keys. No app.ini hand-editing — same env-var pattern.
- Migrate data with `gitea dump` → import, or Gitea's DB migration tooling; SQLite→Postgres
  is not an in-place switch.
- Expect to revisit connection pooling, backups (switch to `pg_dump`), and HA only then.
- Until then, treat the single SQLite file as the source of truth and keep backups frequent.

---

## 9. Security notes

- `DISABLE_REGISTRATION=true` + `INSTALL_LOCK=true`: no public signup, no web installer.
- `REQUIRE_SIGNIN_VIEW=true`: anonymous users can't browse repos.
- `SECRET_KEY` / `INTERNAL_TOKEN` live only in `.env` (gitignored) — rotate if leaked.
- `GITEA_WEBHOOK_ALLOWED_HOSTS` gates webhook egress; widen only for the Phase 3 AI service
  and prefer an explicit host over `*` in production.
- TLS is terminated at Caddy with HSTS; Gitea speaks plain HTTP only on the internal network.
- Revoke the `bootstrap` API token after initial provisioning.

---

# Phase 2 — Gitea Actions CI

Actions is enabled in Gitea (`GITEA__actions__ENABLED=true`) and a single `act_runner`
container executes workflows. CI runs automatically on **push** and **pull_request** for the
pilot repo, and results appear in the Gitea UI (repo → **Actions** tab, and as commit-status
checks on commits/PRs).

## 10. Runner registration

The runner registers once using an instance-level token and persists its identity in
`codebase-runner-data`, so restarts do **not** re-register.

```bash
# Generate a fresh registration token (admin), then put it in .env as RUNNER_REGISTRATION_TOKEN:
docker exec -u git codebase-gitea gitea actions generate-runner-token
docker compose up -d runner

# Verify it's online:
docker exec -u git codebase-gitea sqlite3 /data/gitea/gitea.db \
  "SELECT name, version, last_online>0 AS online FROM action_runner;"
docker logs codebase-runner | tail   # expect "declare successfully" then polling
```
A token is single-use for registration; once `.runner` exists in the volume it's ignored. To
move/reset a runner: `docker compose rm -sf runner && docker volume rm codebase-runner-data`,
generate a new token, `up -d` again.

## 11. The CI workflow

Lives in the **repo** at `.gitea/workflows/ci.yml` (not in `deploy/`). The pilot workflow runs
checkout → env info → shell lint → tests → build, on `push` and `pull_request`. `runs-on:
ubuntu-latest` is mapped by the runner (see below) — it is **not** the GitHub fat image.

Status-check context format is **`<workflow> / <job> (<event>)`**, e.g. `CI / build (pull_request)`.
To gate merges on CI, set that exact context in branch protection (do this *after* the workflow
exists, or PRs block on a never-reported check):
```bash
curl -X PATCH -u codebase-admin:PASS \
  http://127.0.0.1:3000/api/v1/repos/codebase/pilot/branch_protections/main \
  -H 'Content-Type: application/json' \
  -d '{"enable_status_check":true,"status_check_contexts":["CI / build (pull_request)"]}'
```
With this set, a PR needs **both** a green `CI / build (pull_request)` **and** 1 approval to
merge — CI green alone is blocked with *"Does not have enough approvals"* (the human gate).

## 12. Runner labels & images

`runs-on` labels are mapped to container images in `deploy/runner/config.yaml`:
```yaml
labels:
  - "ubuntu-latest:docker://node:20-bookworm"
```
`node:20-bookworm` is a lightweight base with `node` + `git` — enough for checkout and script
steps, but it does **not** preinstall the toolchain GitHub's `ubuntu-latest` image has (docker,
python, aws-cli, build-essential, …). If a workflow needs more, either `apt-get install` in a
step or map the label to a fatter image, e.g.
`"ubuntu-latest:docker://catthehacker/ubuntu:act-latest"` (multi-GB pull). Edit the file and
`docker compose restart runner`.

## 13. Secrets handling

- **Where:** UI → repo or org → **Settings → Actions → Secrets** (or `action_variable`/`secret`
  tables). Org secrets are shared by all org repos; repo secrets are scoped to one repo.
- **In workflows:** `${{ secrets.NAME }}` → injected as masked env vars in the job.
- **Do not** put secrets in `.gitea/workflows/*.yml` or the runner config. The runner has the
  host Docker socket, so treat anything it can read as compromised if a malicious workflow runs.
- Prefer org-level secrets for shared CI creds; rotate on member offboarding.

## 14. Cache strategy

`actions/cache` is served by the runner's built-in cache server (`cache.enabled: true` in
`config.yaml`). It is **node-local**: the cache lives with this runner, so adding more runners
means cache misses across them. For multi-runner setups, point caching at a shared backend
(e.g. an S3-compatible store) instead of per-runner cache. For the prototype, single-runner
local cache is fine. If cache uploads/downloads misbehave on Docker Desktop (cross-network
addressing), disable it (`cache.enabled: false`) — workflows still run, just without caching.

## 15. Runner security & scaling

**Security (the main risk):** the runner runs *untrusted repository code* and is mounted with
`/var/run/docker.sock` — that is effectively **root on the host**. Acceptable for a local,
single-tenant prototype. Before this is shared or hosts untrusted PRs, harden it:
- Run the runner on a **dedicated/isolated host** (not the Gitea host).
- Use **rootless Docker** or **Docker-in-Docker** instead of the host socket.
- Constrain with `container.privileged: false` (already set) and `valid_volumes: []` (already set).
- Disable Actions on forks / require approval to run workflows from outside collaborators.

**Scaling:**
- Vertical: raise `runner.capacity` in `config.yaml` (concurrent jobs per runner).
- Horizontal: add more `runner` containers, each with its **own** registration token + data
  volume + unique `GITEA_RUNNER_NAME`. Jobs are distributed by matching labels.

## 16. CI troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Job stuck "running", no logs | Runner accepted it but the job container is wedged. `docker ps --filter name=GITEA-ACTIONS` to find it; `docker logs <job>` / `docker top <job>`; read live log at `/data/gitea/actions_log/<owner>/<repo>/NN/N.log` inside the gitea container. Remove the container to fail the task and free the slot. |
| Job never starts (waiting) | No runner matches the `runs-on` label, or runner offline. Check `action_runner` table `online` + `docker logs codebase-runner`. Confirm the label exists in `config.yaml`. |
| `actions/checkout` fails to clone | Job container can't reach `gitea:3000`. Ensure `container.network: codebase` in `config.yaml` and that the runner shares the `codebase` network. |
| Reusable action won't download | Gitea fetches actions from github.com by default; the job container needs outbound internet. For air-gapped setups, mirror actions or set `[actions] DEFAULT_ACTIONS_URL`. |
| Run status enum confusion | `action_run.status`: 0 unknown, 1 success, 2 failure, 3 cancelled, 4 skipped, 5 waiting, 6 **running**, 7 blocked. |

## 17. Known compatibility gaps vs GitHub Actions

Gitea Actions is GitHub-*compatible*, not identical. Gaps observed on this deployment:

1. **Artifacts (`actions/upload-artifact`)** — `@v4` is **not supported**; `@v3` **hangs** on
   this setup (the upload retries against an endpoint the internal job container can't reach —
   internal/external URL split). The pilot workflow therefore **omits** artifact upload and
   surfaces build output in the step log instead. Revisit once artifact storage + a
   job-reachable results URL are configured. *(This is why the first pilot run was left to fail
   — it was the diagnostic for this gap.)*
2. **`ubuntu-latest` is not GitHub's image** — it's whatever you map the label to
   (here `node:20-bookworm`). Workflows assuming preinstalled GitHub tooling need adjustment.
3. **Reusable actions come from github.com** — runners need outbound internet (or a mirror);
   not all marketplace actions behave identically under act.
4. **Status-check context naming** differs (`<workflow> / <job> (<event>)`), so branch-protection
   required-checks must use Gitea's format, not a GitHub-style `ci/...` name.
5. **No GitHub-hosted runners** — everything runs on self-hosted runners you operate and secure.

---

# Phase 3 — AI companion service (scaffold)

A standalone service (`deploy/ai-service/`, container `codebase-ai`) that demonstrates the
agent loop **without forking Gitea** — the design doc's preferred "alongside Gitea" extension.
It is plumbing only: no model call yet.

## 18. How the loop works

```
Gitea  ──webhook POST──▶  ai-service:8080/gitea/events  ──Gitea API (bot token)──▶  Gitea
 (PR event)               (verify HMAC, fetch diff)        (comment + commit status)
```

1. **Inbound (Gitea → us):** Gitea POSTs the event to OUR endpoint `POST /gitea/events`.
   The service verifies the `X-Gitea-Signature` HMAC against `WEBHOOK_SECRET` and routes on
   `X-Gitea-Event`. It returns `202` fast (process inline now; move to a worker/queue before
   any slow model call, so Gitea's webhook timeout isn't tripped).
2. **Outbound (us → Gitea):** on a `pull_request` event it fetches the diff
   (`GET /repos/{o}/{r}/pulls/{n}.diff`) and acts back as the **`codebase-ai-bot`** identity:
   posts an issue comment and sets a commit status `codebase-ai/review`.

The bot's actions are attributable (they show as `codebase-ai-bot`, not a human) — this is the
design doc's "agent identity" achieved with a plain scoped token, deferring the harder
first-class-identity question to Phase 5.

## 19. Identity & auth

- **Bot user:** `codebase-ai-bot`, member of the `maintainers` team (so it can see org repos).
- **Token scopes:** `write:issue,write:repository` (minimum to comment + set status). It does
  NOT have `read:user`, admin, etc. Rotate via:
  ```bash
  docker exec -u git codebase-gitea gitea admin user generate-access-token \
    --username codebase-ai-bot --scopes write:issue,write:repository --token-name ai-service --raw
  ```
  Update `AI_BOT_TOKEN` in `.env` and `docker compose up -d ai-service`.
- **Webhook secret:** `AI_WEBHOOK_SECRET` (`openssl rand -hex 32`), shared between the Gitea
  webhook config and the service. The service rejects unsigned/mismatched payloads with `401`.

## 20. Registering the webhook (deferred — URL is a placeholder)

Not registered during bootstrap on purpose: `AI_WEBHOOK_TARGET_URL` is a placeholder until the
service's network location is final. When ready:
```bash
cd deploy && set -a && . ./.env && set +a
ADMIN_PASSWORD='...' ./scripts/register-webhook.sh
```
This creates an **org-level** webhook on `codebase` for `pull_request, push, issue_comment`
pointing at `AI_WEBHOOK_TARGET_URL` (default internal `http://ai-service:8080/gitea/events`).
For same-network delivery, ensure `GITEA_WEBHOOK_ALLOWED_HOSTS` permits the target host.
Inspect deliveries (payload + response) in the UI: org → Settings → Webhooks → the hook.

## 21. Testing without a registered webhook

You can replay a signed event straight at the endpoint (this is how the scaffold was validated):
```bash
# from inside the ai-service container (has the secret + can reach gitea)
docker exec -e SHA="$(git rev-parse HEAD)" -i codebase-ai python - <<'PY'
import os,json,hmac,hashlib,urllib.request
p={"action":"opened","repository":{"name":"pilot","owner":{"login":"codebase"}},
   "pull_request":{"number":1,"head":{"sha":os.environ["SHA"]}}}
b=json.dumps(p).encode()
sig=hmac.new(os.environ["WEBHOOK_SECRET"].encode(),b,hashlib.sha256).hexdigest()
r=urllib.request.Request("http://localhost:8080/gitea/events",data=b,method="POST",
  headers={"X-Gitea-Event":"pull_request","X-Gitea-Signature":sig,"Content-Type":"application/json"})
print(urllib.request.urlopen(r).status)
PY
docker logs codebase-ai | tail   # expect: comment 201, commit status 201
```
Health check: `docker exec codebase-gitea curl -fsS http://ai-service:8080/health`.

## 22. AI-service security notes

- Unlike the runner, this service runs **no repository code** and has **no host socket** — it's
  an unprivileged, non-root container. Keep it that way.
- Always verify the HMAC signature; never run with `WEBHOOK_SECRET` empty in production.
- Keep the bot token least-privilege; treat it like any credential (only in `.env`).
- Make handlers **idempotent** (webhooks redeliver) — key off delivery id / commit sha.
- Log every inbound event and outbound API call — the seed of the Phase 6 audit trail.

## 23. Replacing the scaffold with real AI

`review_pull_request(diff)` in `ai-service/app.py` is the single seam. Swap its body for a model
call (feed the diff + Phase 4 context-service output), return structured findings, and keep the
same comment/commit-status callbacks. Everything else — transport, auth, identity — stays.
