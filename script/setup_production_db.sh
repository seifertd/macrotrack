#!/usr/bin/env bash
#
# Creates the production role, the four Solid-* databases, and the Capistrano
# linked_file shared/config/database.yml on the deploy host.
#
# Run on das as root:  sudo bash script/setup_production_db.sh
#
# Idempotent: re-running rotates the password and rewrites database.yml, which
# is also how you recover if the two ever drift apart. The password is generated
# here and never leaves the host.
set -euo pipefail

APP_DB_USER=macrotrack
SHARED_CONFIG=/home/doug/webapps/macrotrack/production/shared/config
PG_MAJOR=18

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root: sudo bash $0" >&2
  exit 1
fi

# Don't assume 5432 — PG 14 already squats on 5434 on this box.
PORT=$(pg_lsclusters -h | awk -v v="$PG_MAJOR" '$1 == v && $2 == "main" { print $3 }')
if [ -z "$PORT" ]; then
  echo "no PostgreSQL $PG_MAJOR 'main' cluster found; run pg_lsclusters" >&2
  exit 1
fi
echo "PostgreSQL $PG_MAJOR main cluster is on port $PORT"

PASS=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)

sudo -u postgres psql -p "$PORT" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${APP_DB_USER}') THEN
    CREATE ROLE ${APP_DB_USER} LOGIN PASSWORD '${PASS}';
  ELSE
    ALTER ROLE ${APP_DB_USER} LOGIN PASSWORD '${PASS}';
  END IF;
END
\$\$;
SQL

for db in macrotrack_production macrotrack_production_cache \
          macrotrack_production_queue macrotrack_production_cable; do
  if sudo -u postgres psql -p "$PORT" -tAc \
      "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
    echo "  $db already exists"
  else
    sudo -u postgres createdb -p "$PORT" -O "$APP_DB_USER" "$db"
    echo "  created $db"
  fi
done

# pg_trgm needs superuser, so create it here; the migration's enable_extension
# emits CREATE EXTENSION IF NOT EXISTS and becomes a no-op.
sudo -u postgres psql -p "$PORT" -d macrotrack_production -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'

install -d -o doug -g doug -m 750 "$SHARED_CONFIG"
cat > "$SHARED_CONFIG/database.yml" <<YML
# Written by script/setup_production_db.sh. Not in git — this is a Capistrano
# linked_file, symlinked into each release from shared/config/.
default: &default
  adapter: postgresql
  encoding: unicode
  host: 127.0.0.1
  port: ${PORT}
  username: ${APP_DB_USER}
  password: "${PASS}"
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>

production:
  primary: &primary_production
    <<: *default
    database: macrotrack_production
  cache:
    <<: *primary_production
    database: macrotrack_production_cache
    migrations_paths: db/cache_migrate
  queue:
    <<: *primary_production
    database: macrotrack_production_queue
    migrations_paths: db/queue_migrate
  cable:
    <<: *primary_production
    database: macrotrack_production_cable
    migrations_paths: db/cable_migrate
YML

chown doug:doug "$SHARED_CONFIG/database.yml"
chmod 600 "$SHARED_CONFIG/database.yml"
echo "wrote $SHARED_CONFIG/database.yml (port $PORT, user $APP_DB_USER)"
