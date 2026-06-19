#!/usr/bin/env bash
# Restore a Gitea instance from a `gitea dump` zip produced by backup.sh.
#
# WARNING: this overwrites the current instance's data. Stop traffic first.
# `gitea dump` has no one-shot restore command — we unpack the archive and place
# each component into the data volume by hand. See the runbook for the full walkthrough.
#
#   ./restore.sh ./backups/gitea-dump-<stamp>.zip
set -euo pipefail

DUMP="${1:?usage: restore.sh <path-to-gitea-dump.zip>}"
GITEA_CONTAINER="${GITEA_CONTAINER:-codebase-gitea}"

if [[ ! -f "$DUMP" ]]; then
  echo "ERROR: dump file not found: $DUMP" >&2
  exit 1
fi

cat <<EOF
This will OVERWRITE the data in container '$GITEA_CONTAINER' with the contents of:
  $DUMP

Recommended manual sequence (run from the deploy/ dir):
  1) docker compose stop gitea
  2) Unzip the dump locally:        unzip "$DUMP" -d /tmp/gitea-restore
  3) Restore the database:          copy gitea-db.sql -> import into a fresh sqlite gitea.db,
                                    OR for sqlite just restore the gitea-repo/ + data and the
                                    bundled gitea.db if present in your dump.
  4) Restore repositories:          copy gitea-repo/* into the volume at /data/git/repositories
  5) Restore data + config:         copy data/ and app.ini (custom/conf/app.ini) into /data/gitea
  6) Fix ownership:                 chown -R 1000:1000 inside the volume
  7) docker compose start gitea && tail logs

This script intentionally does not auto-apply destructive steps. Follow the runbook
("Backup & restore") so you can verify each component before starting Gitea again.
EOF
