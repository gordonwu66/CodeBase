#!/usr/bin/env bash
# Create a consistent backup of the Gitea instance using the built-in `gitea dump`.
# This captures the SQLite DB, repositories, LFS, config, and avatars into one archive.
#
# Output: ./backups/gitea-dump-<UTC timestamp>.zip on the host.
# Also snapshot the Caddy data volume separately if you want to preserve issued certs.
set -euo pipefail

GITEA_CONTAINER="${GITEA_CONTAINER:-codebase-gitea}"
BACKUP_DIR="${BACKUP_DIR:-$(cd "$(dirname "$0")/.." && pwd)/backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="gitea-dump-${STAMP}.zip"

mkdir -p "$BACKUP_DIR"

echo "==> Running gitea dump inside $GITEA_CONTAINER"
# Dump to /tmp inside the container (must run as the git user), then copy it out.
docker exec -u git "$GITEA_CONTAINER" bash -lc "cd /tmp && gitea dump --type zip --file /tmp/${NAME}"
docker cp "${GITEA_CONTAINER}:/tmp/${NAME}" "${BACKUP_DIR}/${NAME}"
docker exec -u git "$GITEA_CONTAINER" rm -f "/tmp/${NAME}"

echo "==> Backup written: ${BACKUP_DIR}/${NAME}"
echo "    Optional: docker run --rm -v codebase-caddy-data:/d -v \"${BACKUP_DIR}\":/b alpine \\"
echo "              tar czf /b/caddy-data-${STAMP}.tgz -C /d ."
