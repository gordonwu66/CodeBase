#!/usr/bin/env bash
# Bootstrap the admin user, initial org/team/repo, and branch protection that mirrors
# our current review + merge discipline. Idempotent: re-running skips things that exist.
#
# Run once after `docker compose up -d`. Requires the stack to be healthy.
#
# Env (override as needed):
#   ADMIN_USER       default: codebase-admin
#   ADMIN_EMAIL      default: admin@example.com
#   ADMIN_PASSWORD   REQUIRED (no default — set it before running)
#   ORG              default: codebase
#   TEAM             default: maintainers
#   PILOT_REPO       default: pilot
#   GITEA_CONTAINER  default: codebase-gitea
#   API_BASE         default: http://localhost:3000  (in-container loopback via the proxy below)
set -euo pipefail

ADMIN_USER="${ADMIN_USER:-codebase-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ORG="${ORG:-codebase}"
TEAM="${TEAM:-maintainers}"
PILOT_REPO="${PILOT_REPO:-pilot}"
GITEA_CONTAINER="${GITEA_CONTAINER:-codebase-gitea}"

if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
  echo "ERROR: set ADMIN_PASSWORD before running (it bootstraps the first admin)." >&2
  exit 1
fi

dex() { docker exec -u git "$GITEA_CONTAINER" "$@"; }

echo "==> 1/5 Ensuring admin user '$ADMIN_USER' exists"
if dex gitea admin user list --admin | awk '{print $2}' | grep -qx "$ADMIN_USER"; then
  echo "    admin user already present, skipping"
else
  dex gitea admin user create \
    --username "$ADMIN_USER" --password "$ADMIN_PASSWORD" --email "$ADMIN_EMAIL" \
    --admin --must-change-password=false
fi

echo "==> 2/5 Minting a scoped API token for bootstrap calls"
# Reuse a named token if it already exists, otherwise create one.
TOKEN="$(dex gitea admin user generate-access-token \
  --username "$ADMIN_USER" --scopes write:organization,write:repository,write:user \
  --token-name bootstrap --raw 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
  echo "    'bootstrap' token already exists; delete it in the UI or pass a fresh ADMIN token to re-run API steps." >&2
  echo "    Skipping API-driven org/repo/protection steps." >&2
  exit 0
fi

# Talk to the API from inside the gitea container so we don't depend on host networking/TLS.
api() {
  local method="$1" path="$2"; shift 2
  dex curl -fsS -X "$method" \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/json" \
    "http://127.0.0.1:3000/api/v1${path}" "$@"
}

echo "==> 3/5 Ensuring org '$ORG' and team '$TEAM'"
api POST /orgs -d "{\"username\":\"$ORG\",\"visibility\":\"private\"}" >/dev/null 2>&1 || echo "    org exists, skipping"
# includes_all_repositories=true so the team (and members like the AI bot) can access every
# org repo. Without it, a newly created repo is only attached to the Owners team, and team
# members get 404s on it.
api POST "/orgs/$ORG/teams" -d "{
  \"name\":\"$TEAM\",
  \"permission\":\"write\",
  \"units\":[\"repo.code\",\"repo.issues\",\"repo.pulls\",\"repo.releases\"],
  \"can_create_org_repo\":true,
  \"includes_all_repositories\":true
}" >/dev/null 2>&1 || echo "    team exists, skipping"

echo "==> 4/5 Ensuring pilot repo '$ORG/$PILOT_REPO'"
api POST "/orgs/$ORG/repos" -d "{
  \"name\":\"$PILOT_REPO\",
  \"private\":true,
  \"auto_init\":true,
  \"default_branch\":\"main\",
  \"description\":\"CodeBase Phase 1 pilot repository\"
}" >/dev/null 2>&1 || echo "    repo exists, skipping"

echo "==> 5/5 Enabling branch protection on 'main' (PR review, no force-push)"
# Mirrors current discipline: protected default branch, >=1 approval, dismiss stale reviews,
# block direct pushes and force-pushes.
#
# NOTE on status checks: we do NOT require a CI status context here. A required context that
# has never been reported counts as *pending* and would block every PR on a brand-new repo
# (the workflow doesn't exist yet — chicken/egg). Add the CI gate AFTER porting the workflow,
# once you know its real context. Gitea Actions reports "<workflow> / <job> (<event>)", e.g.:
#
#   curl -X PATCH -u admin:pass \
#     http://127.0.0.1:3000/api/v1/repos/$ORG/$PILOT_REPO/branch_protections/main \
#     -H 'Content-Type: application/json' \
#     -d '{"enable_status_check":true,"status_check_contexts":["CI / build (pull_request)"]}'
api POST "/repos/$ORG/$PILOT_REPO/branch_protections" -d '{
  "branch_name": "main",
  "enable_push": false,
  "require_signed_commits": false,
  "enable_merge_whitelist": false,
  "required_approvals": 1,
  "enable_approvals_whitelist": false,
  "dismiss_stale_approvals": true,
  "block_on_rejected_reviews": true,
  "block_on_outdated_branch": true
}' >/dev/null 2>&1 || \
  api PATCH "/repos/$ORG/$PILOT_REPO/branch_protections/main" -d '{
    "required_approvals": 1,
    "dismiss_stale_approvals": true,
    "block_on_rejected_reviews": true
  }' >/dev/null 2>&1 || echo "    could not set protection (check token scopes / repo name)"

echo
echo "Done. Pilot repo: https://${GITEA_DOMAIN:-<domain>}/$ORG/$PILOT_REPO"
echo "NOTE: store the printed bootstrap token securely; revoke it once provisioning is finished."
