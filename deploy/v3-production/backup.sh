#!/bin/sh
set -eu
umask 077

PROJECT_DIR=/opt/1panel/apps/local/grok2api
BACKUP_DIR=/opt/1panel/backups/grok2api
PASS_FILE=/root/.config/grok2api-backup.pass
VOLUME_NAME=grok2api-data

test -f "$PROJECT_DIR/config.yaml"
test -f "$PROJECT_DIR/docker-compose.yml"
test -f "$PASS_FILE"

mkdir -p "$BACKUP_DIR"
TMP=$(mktemp -d "$BACKUP_DIR/.tmp.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

MOUNTPOINT=$(docker volume inspect "$VOLUME_NAME" --format '{{.Mountpoint}}')
SOURCE_DB="$MOUNTPOINT/backend.db"
test -f "$SOURCE_DB"

python3 - "$SOURCE_DB" "$TMP/backend.db" <<'PY'
import sqlite3
import sys

source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
target = sqlite3.connect(sys.argv[2])
with target:
    source.backup(target)
check = target.execute("PRAGMA integrity_check").fetchone()[0]
target.close()
source.close()
if check != "ok":
    raise SystemExit(f"backup integrity check failed: {check}")
PY

install -m 0600 "$PROJECT_DIR/config.yaml" "$TMP/config.yaml"
install -m 0600 "$PROJECT_DIR/docker-compose.yml" "$TMP/docker-compose.yml"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DAILY="$BACKUP_DIR/daily-$STAMP.tar.enc"
tar -C "$TMP" -cf - . | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 -pass "file:$PASS_FILE" -out "$DAILY"
chmod 0600 "$DAILY"

if [ "$(date +%u)" = 7 ]; then
  cp "$DAILY" "$BACKUP_DIR/weekly-$STAMP.tar.enc"
fi

# Backup filenames are generated internally from UTC timestamps, so sorting the
# controlled names with ls is safe and preserves POSIX shell portability.
# shellcheck disable=SC2012
ls -1t "$BACKUP_DIR"/daily-*.tar.enc 2>/dev/null | awk 'NR > 7' | while IFS= read -r old; do rm -f -- "$old"; done
# shellcheck disable=SC2012
ls -1t "$BACKUP_DIR"/weekly-*.tar.enc 2>/dev/null | awk 'NR > 4' | while IFS= read -r old; do rm -f -- "$old"; done

echo "backup created: $DAILY"
