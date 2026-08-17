#!/usr/bin/env bash
#
# Restore-test the most recent production dump into a scratch database and count
# rows. An untested backup is a belief, not a backup.
#
# Run on das as root (createdb/dropdb as the postgres superuser):
#   sudo bash /home/doug/webapps/macrotrack/production/current/script/restore_test.sh
#
# Leaves nothing behind — the scratch database is dropped on exit, including on
# failure.
set -euo pipefail

BACKUP_DIR=/home/doug/webapps/backups/macrotrack
SCRATCH=macrotrack_restore_test
PG_MAJOR=18

PORT=$(pg_lsclusters -h | awk -v v="$PG_MAJOR" '$1 == v && $2 == "main" { print $3 }')
LATEST=$(ls -t "$BACKUP_DIR"/macrotrack_production-*.dump 2>/dev/null | head -1)

if [ -z "$LATEST" ]; then
  echo "no dumps found in $BACKUP_DIR" >&2
  exit 1
fi
echo "restoring $LATEST into $SCRATCH on port $PORT"

cleanup() { sudo -u postgres dropdb -p "$PORT" --if-exists "$SCRATCH"; }
trap cleanup EXIT

sudo -u postgres dropdb -p "$PORT" --if-exists "$SCRATCH"
sudo -u postgres createdb -p "$PORT" "$SCRATCH"
sudo -u postgres psql -p "$PORT" -d "$SCRATCH" -q -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'
sudo -u postgres pg_restore -p "$PORT" -d "$SCRATCH" --no-owner --no-acl "$LATEST"

echo
echo "row counts in the restored copy:"
sudo -u postgres psql -p "$PORT" -d "$SCRATCH" -c "
  SELECT relname AS table, n_live_tup AS rows
  FROM pg_stat_user_tables
  WHERE n_live_tup > 0
  ORDER BY n_live_tup DESC;"

# Compare against production so a truncated dump can't pass silently.
echo "users/meal_entries in production vs restored:"
sudo -u postgres psql -p "$PORT" -d macrotrack_production -tAc \
  "SELECT 'production: users=' || (SELECT count(*) FROM users) ||
          ' meal_entries=' || (SELECT count(*) FROM meal_entries)"
sudo -u postgres psql -p "$PORT" -d "$SCRATCH" -tAc \
  "SELECT 'restored:   users=' || (SELECT count(*) FROM users) ||
          ' meal_entries=' || (SELECT count(*) FROM meal_entries)"
