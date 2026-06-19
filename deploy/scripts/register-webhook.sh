#!/usr/bin/env bash
# Register the org-level webhook that points Gitea at the AI companion service.
#
# Intentionally NOT run during bootstrap — the target URL is a placeholder until the
# service's network location is finalized (see AI_WEBHOOK_TARGET_URL in .env). Run this
# once you're ready to start delivering events.
#
# Env:
#   ORG                    default: codebase
#   ADMIN                  default: codebase-admin
#   ADMIN_PASSWORD         REQUIRED
#   AI_WEBHOOK_TARGET_URL  from .env (placeholder by default)
#   AI_WEBHOOK_SECRET      from .env (HMAC secret, must match the service)
set -euo pipefail

ORG="${ORG:-codebase}"
ADMIN="${ADMIN:-codebase-admin}"
: "${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"
: "${AI_WEBHOOK_TARGET_URL:?set AI_WEBHOOK_TARGET_URL (or source deploy/.env)}"
: "${AI_WEBHOOK_SECRET:?set AI_WEBHOOK_SECRET (or source deploy/.env)}"
GITEA_CONTAINER="${GITEA_CONTAINER:-codebase-gitea}"

echo "Registering org webhook on '$ORG' -> $AI_WEBHOOK_TARGET_URL"
docker exec -i -u git "$GITEA_CONTAINER" curl -fsS -u "$ADMIN:$ADMIN_PASSWORD" \
  -X POST "http://127.0.0.1:3000/api/v1/orgs/$ORG/hooks" \
  -H 'Content-Type: application/json' \
  -d @- <<JSON
{
  "type": "gitea",
  "active": true,
  "events": ["pull_request", "push", "issue_comment"],
  "config": {
    "url": "${AI_WEBHOOK_TARGET_URL}",
    "content_type": "json",
    "secret": "${AI_WEBHOOK_SECRET}"
  }
}
JSON
echo
echo "Done. Inspect deliveries in the UI: $ORG -> Settings -> Webhooks."
