#!/usr/bin/env bash
#
# Nightly production backup. Runs on das as doug, from the deployed release, so
# cron always picks up the current version:
#
#   /home/doug/webapps/macrotrack/production/current/script/backup_production_db.sh
#
# Dumps the primary database only. cache/queue/cable are Solid-* scratch state —
# regenerable from db/*_schema.rb, and nothing in them is worth restoring.
set -euo pipefail

SHARED=/home/doug/webapps/macrotrack/production/shared
BACKUP_DIR=/home/doug/webapps/backups/macrotrack
RETAIN_DAYS=30
DB=macrotrack_production

mkdir -p "$BACKUP_DIR"
exec >>"$BACKUP_DIR/backup.log" 2>&1
echo "=== $(date -Is) starting backup"

# The password lives only in shared/config/database.yml (mode 600). Parsing it
# keeps a single source of truth rather than a second copy in .pgpass.
DB_YML="$SHARED/config/database.yml"
PORT=$(awk '/^  port:/ { print $2; exit }' "$DB_YML")
USER=$(awk '/^  username:/ { print $2; exit }' "$DB_YML")
PASS=$(sed -n 's/^  password: "\(.*\)"$/\1/p' "$DB_YML" | head -1)

if [ -z "$PORT" ] || [ -z "$USER" ] || [ -z "$PASS" ]; then
  echo "FAILED: could not parse $DB_YML"
  exit 1
fi

STAMP=$(date +%F)
OUT="$BACKUP_DIR/${DB}-${STAMP}.dump"

# Custom format rather than plain SQL + gzip: already compressed, and pg_restore
# can then do selective / parallel restores off the same file.
PGPASSWORD="$PASS" pg_dump -h 127.0.0.1 -p "$PORT" -U "$USER" \
  -Fc --no-owner --no-acl -f "$OUT.tmp" "$DB"
mv "$OUT.tmp" "$OUT"

SIZE=$(du -h "$OUT" | cut -f1)
echo "wrote $OUT ($SIZE)"

# A zero-table dump means something is wrong even if pg_dump exited 0.
TABLES=$(PGPASSWORD="$PASS" pg_restore -l "$OUT" | grep -c "TABLE DATA" || true)
if [ "$TABLES" -eq 0 ]; then
  echo "FAILED: dump contains no table data"
  exit 1
fi
echo "dump contains $TABLES tables with data"

find "$BACKUP_DIR" -name "${DB}-*.dump" -mtime "+$RETAIN_DAYS" -print -delete

# Marker for spotting a silently dead cron: if this file stops advancing, the
# backups stopped even though the directory still looks healthy.
date -Is > "$BACKUP_DIR/last_success"
echo "=== $(date -Is) backup ok"
