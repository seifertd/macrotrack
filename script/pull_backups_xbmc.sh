#!/usr/bin/env bash
#
# Offsite half of the backup. Runs on the xbmc box (seifert-media) as doug,
# installed at ~/Tools/pull_macros_backup.sh and driven by cron. Pulls rather
# than das pushing, so das holds no credential for this machine.
#
# The key it uses is restricted on the das side to:
#   command="/usr/bin/rrsync -ro /home/doug/webapps/backups/macrotrack",restrict
# so it can only read that one directory — no shell, no forwarding.
set -euo pipefail

REMOTE=doug@macros.dseifert.net
KEY=/home/doug/.ssh/id_das_backup
DEST=/media/backup/macros-backups
STALE_HOURS=36
LOG="$DEST/pull.log"

exec >>"$LOG" 2>&1
echo "=== $(date -Is) starting pull"

# No --delete: das prunes at 30 days, and keeping deeper history here is the
# whole point of a second copy. The dumps are ~33K, so this stays cheap.
rsync -az --stats \
  -e "ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=30" \
  "$REMOTE:/" "$DEST/" | tail -3

# A dead cron on das looks identical to a healthy one from here — the directory
# is still full of yesterday's dumps. Check the marker's age, not the listing.
if [ -f "$DEST/last_success" ]; then
  LAST=$(date -d "$(cat "$DEST/last_success")" +%s)
  AGE_H=$(( ($(date +%s) - LAST) / 3600 ))
  if [ "$AGE_H" -gt "$STALE_HOURS" ]; then
    echo "WARNING: newest das-side backup is ${AGE_H}h old (>${STALE_HOURS}h)"
    exit 1
  fi
  echo "ok: newest das-side backup is ${AGE_H}h old"
else
  echo "WARNING: no last_success marker found"
  exit 1
fi

COUNT=$(ls -1 "$DEST"/macrotrack_production-*.dump 2>/dev/null | wc -l)
echo "=== $(date -Is) pull ok, $COUNT dumps held locally"
