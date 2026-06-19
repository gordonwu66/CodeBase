#!/usr/bin/env bash
# Onboard a developer: create their Gitea account and add them to an org team.
# Idempotent — re-running for an existing user just (re)asserts team membership.
#
# Registration is disabled (DISABLE_REGISTRATION=true), so accounts are admin-minted.
# New users get a temporary password and must change it on first login.
#
# Usage:
#   DEV_USER=alice DEV_EMAIL=alice@example.com ./add-dev.sh
#   DEV_USER=bob DEV_EMAIL=bob@example.com TEAM=maintainers ./add-dev.sh
#
# Env:
#   DEV_USER         REQUIRED  login name  (NOT named USERNAME — that's a special var in zsh)
#   DEV_EMAIL        REQUIRED  email (must be unique)
#   TEAM             default: developers   (org team to join)
#   TEMP_PASSWORD    default: generated     (printed once — hand to the user over a secure channel)
#   ORG              default: codebase
#   ADMIN_USER       default: codebase-admin
#   GITEA_CONTAINER  default: codebase-gitea
set -euo pipefail

DEV_USER="${DEV_USER:?set DEV_USER}"
DEV_EMAIL="${DEV_EMAIL:?set DEV_EMAIL}"
TEAM="${TEAM:-developers}"
ORG="${ORG:-codebase}"
ADMIN_USER="${ADMIN_USER:-codebase-admin}"
GITEA_CONTAINER="${GITEA_CONTAINER:-codebase-gitea}"
# Single openssl call — avoid a `tr | head` pipe, which trips `set -o pipefail` via SIGPIPE.
TEMP_PASSWORD="${TEMP_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)}"

dex() { docker exec -u git "$GITEA_CONTAINER" "$@"; }

echo "==> 1/4 Ensuring user '$DEV_USER' exists"
if dex gitea admin user list | awk '{print $2}' | grep -qx "$DEV_USER"; then
  echo "    user already present, skipping create"
else
  dex gitea admin user create \
    --username "$DEV_USER" --email "$DEV_EMAIL" \
    --password "$TEMP_PASSWORD" --must-change-password=true
  echo "    created. TEMP PASSWORD for $DEV_USER: $TEMP_PASSWORD"
  echo "    (they will be forced to change it at first login)"
fi

echo "==> 2/4 Minting a scoped, per-run admin token"
TS=$(date +%s)
TOKEN="$(dex gitea admin user generate-access-token --username "$ADMIN_USER" \
  --scopes write:organization --token-name "addev-$TS" --raw)"

api() {
  local method="$1" path="$2"; shift 2
  dex curl -fsS -X "$method" \
    -H "Authorization: token $TOKEN" -H "Content-Type: application/json" \
    "http://127.0.0.1:3000/api/v1${path}" "$@"
}

# Always revoke the per-run token, even on failure. Gitea's token-DELETE API needs basic
# auth, so we clear it straight from the DB (same store the API writes to).
cleanup() {
  dex sh -c "sqlite3 /data/gitea/gitea.db \"DELETE FROM access_token WHERE name='addev-$TS';\"" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> 3/4 Resolving team id for '$ORG/$TEAM'"
# The by-name endpoint (/orgs/{org}/teams/{team}) 404s on Gitea 1.22.6, so list and filter.
# Split objects onto separate lines, keep the one with our exact team name, read its id.
TEAM_ID="$(api GET "/orgs/$ORG/teams" \
  | tr '}' '\n' | grep "\"name\":\"$TEAM\"" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2 || true)"
if [[ -z "$TEAM_ID" ]]; then
  echo "ERROR: team '$TEAM' not found in org '$ORG'." >&2
  exit 1
fi

echo "==> 4/4 Adding '$DEV_USER' to team '$TEAM' (id $TEAM_ID)"
api PUT "/teams/$TEAM_ID/members/$DEV_USER" >/dev/null
echo "    done"

echo
echo "Onboarded $DEV_USER -> $ORG/$TEAM"
echo "Login: https://${GITEA_DOMAIN:-gitea.localhost}/  (user: $DEV_USER)"
