# Grok2API v3 Production Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the official Grok2API v3.0.7 image as a private, hardened OpenAI Chat Completions gateway on the existing zixungou server, with a separately protected web admin.

**Architecture:** Run one Go-based Grok2API container on `127.0.0.1:8998` with SQLite and in-memory runtime state. Reuse 1Panel OpenResty for two Cloudflare-proxied domains: the API host exposes only `/v1/models` and `/v1/chat/completions`, while the admin host is protected by Cloudflare Access and exposes the React admin but no inference routes.

**Tech Stack:** Docker Compose, `ghcr.io/chenyme/grok2api:v3.0.7` for linux/amd64, Go-based Grok2API v3, SQLite, 1Panel OpenResty, Cloudflare Proxy and Cloudflare Access, POSIX shell, systemd timer.

---

## File map

- Modify: `.gitignore` — exclude generated production secrets and local backup artifacts.
- Create: `deploy/v3-production/test-bundle.sh` — static and Compose validation for the deployment bundle.
- Create: `deploy/v3-production/docker-compose.yml` — pinned, loopback-only production container.
- Create: `deploy/v3-production/render-config.sh` — generate secrets and the first-boot `config.yaml` without printing them.
- Create: `deploy/v3-production/finalize-bootstrap.sh` — remove the bootstrap admin block after first login.
- Create: `deploy/v3-production/openresty/01-grok-api-limits.conf` — shared IP rate-limit zone.
- Create: `deploy/v3-production/openresty/grok-api.root.conf` — exact public API route allowlist and SSE proxy settings.
- Create: `deploy/v3-production/openresty/grok-admin.root.conf` — admin proxy with inference paths denied.
- Create: `deploy/v3-production/backup.sh` — consistent encrypted SQLite/config backups with retention.
- Create: `deploy/v3-production/systemd/grok2api-backup.service` — one-shot backup unit.
- Create: `deploy/v3-production/systemd/grok2api-backup.timer` — daily backup schedule.
- Create: `deploy/v3-production/verify.sh` — public route, auth, chat, tools, and search smoke tests.
- Create: `deploy/v3-production/README.md` — exact operating, upgrade, backup, and rollback commands.
- Create remotely: `/opt/1panel/apps/local/grok2api/config.yaml` — generated secret configuration, never committed.
- Create remotely: `/opt/1panel/www/sites/grok-api/proxy/root.conf` — installed API proxy fragment.
- Create remotely: `/opt/1panel/www/sites/grok-admin/proxy/root.conf` — installed admin proxy fragment.

## Task 1: Add deployment bundle guardrails

**Files:**
- Modify: `.gitignore`
- Create: `deploy/v3-production/test-bundle.sh`

- [ ] **Step 1: Add the failing bundle test**

Create `deploy/v3-production/test-bundle.sh`:

```sh
#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
BUNDLE="$ROOT/deploy/v3-production"

need_file() {
  test -f "$BUNDLE/$1" || {
    echo "missing deployment file: $1" >&2
    exit 1
  }
}

for file in \
  docker-compose.yml \
  render-config.sh \
  finalize-bootstrap.sh \
  backup.sh \
  verify.sh \
  README.md \
  openresty/01-grok-api-limits.conf \
  openresty/grok-api.root.conf \
  openresty/grok-admin.root.conf \
  systemd/grok2api-backup.service \
  systemd/grok2api-backup.timer
do
  need_file "$file"
done

docker compose -f "$BUNDLE/docker-compose.yml" config >/tmp/grok2api-v3-compose.rendered

grep -Fq 'host_ip: 127.0.0.1' /tmp/grok2api-v3-compose.rendered
grep -Fq 'published: "8998"' /tmp/grok2api-v3-compose.rendered
grep -Fq 'ghcr.io/chenyme/grok2api:v3.0.7@sha256:fe87bfb46ed14c5fbac7211fc7c88298588953a83d6f043ee5d4c2c595012707' "$BUNDLE/docker-compose.yml"
grep -Fq 'no-new-privileges:true' "$BUNDLE/docker-compose.yml"
grep -Fq 'mem_limit: 384m' "$BUNDLE/docker-compose.yml"
grep -Fq 'pids_limit: 128' "$BUNDLE/docker-compose.yml"

grep -Fq 'location = /v1/models' "$BUNDLE/openresty/grok-api.root.conf"
grep -Fq 'location = /v1/chat/completions' "$BUNDLE/openresty/grok-api.root.conf"
grep -Fq 'location /' "$BUNDLE/openresty/grok-api.root.conf"
grep -Fq 'return 404' "$BUNDLE/openresty/grok-api.root.conf"
grep -Fq 'proxy_buffering off' "$BUNDLE/openresty/grok-api.root.conf"
grep -Fq 'location ^~ /v1/' "$BUNDLE/openresty/grok-admin.root.conf"

if grep -R --exclude=test-bundle.sh -nE '(sso=[^[:space:]]+|g2a_[A-Za-z0-9]{16,}|credentialEncryptionKey: "[A-Za-z0-9+/=]{40,}"|jwtSecret: "[A-Fa-f0-9]{64}")' "$BUNDLE"; then
  echo 'deployment bundle appears to contain a secret' >&2
  exit 1
fi

echo 'deployment bundle checks passed'
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
chmod +x deploy/v3-production/test-bundle.sh
deploy/v3-production/test-bundle.sh
```

Expected: FAIL with `missing deployment file: docker-compose.yml`.

- [ ] **Step 3: Extend `.gitignore` for generated secrets**

Append:

```gitignore
# Grok2API v3 production-generated secrets
deploy/v3-production/config.yaml
deploy/v3-production/bootstrap-credentials.txt
deploy/v3-production/backup.pass
deploy/v3-production/backups/
```

- [ ] **Step 4: Commit the guardrails**

```bash
git add .gitignore deploy/v3-production/test-bundle.sh
git commit -m "test: add grok2api v3 deployment guardrails"
```

## Task 2: Build the pinned container and secret configuration

**Files:**
- Create: `deploy/v3-production/docker-compose.yml`
- Create: `deploy/v3-production/render-config.sh`
- Create: `deploy/v3-production/finalize-bootstrap.sh`

- [ ] **Step 1: Create the production Compose file**

Create `deploy/v3-production/docker-compose.yml`:

```yaml
name: grok2api

services:
  grok2api:
    container_name: grok2api-v3
    image: ghcr.io/chenyme/grok2api:v3.0.7@sha256:fe87bfb46ed14c5fbac7211fc7c88298588953a83d6f043ee5d4c2c595012707
    ports:
      - "127.0.0.1:8998:8000"
    environment:
      TZ: Asia/Shanghai
    volumes:
      - ./config.yaml:/run/grok2api/config.yaml:ro
      - grok2api-data:/app/data
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
    pids_limit: 128
    mem_limit: 384m
    cpus: 0.75
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"

volumes:
  grok2api-data:
    name: grok2api-data
```

- [ ] **Step 2: Create the secret config renderer**

Create `deploy/v3-production/render-config.sh`:

```sh
#!/bin/sh
set -eu
umask 077

TARGET=${1:-config.yaml}
CREDENTIALS=${2:-bootstrap-credentials.txt}
BACKUP_PASS=${3:-backup.pass}

for path in "$TARGET" "$CREDENTIALS" "$BACKUP_PASS"; do
  if [ -e "$path" ]; then
    echo "refusing to overwrite existing file: $path" >&2
    exit 1
  fi
done

JWT_SECRET=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '\n')
ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
BACKUP_PASSWORD=$(openssl rand -base64 48 | tr -d '\n')

{
  printf '%s\n' 'server:'
  printf '%s\n' '  listen: "127.0.0.1:8000"'
  printf '%s\n' '  maxBodyBytes: 1048576'
  printf '%s\n' '  maxConcurrentRequests: 16'
  printf '%s\n' '  readTimeout: 15m'
  printf '%s\n' '  requestTimeout: 15m'
  printf '%s\n' '  swaggerEnabled: false'
  printf '%s\n' 'auth:'
  printf '%s\n' '  accessTokenTTL: 15m'
  printf '%s\n' '  refreshTokenTTL: 168h'
  printf '%s\n' '  secureCookies: true'
  printf '%s\n' 'secrets:'
  printf '  jwtSecret: "%s"\n' "$JWT_SECRET"
  printf '  credentialEncryptionKey: "%s"\n' "$ENCRYPTION_KEY"
  printf '%s\n' 'bootstrapAdmin:'
  printf '%s\n' '  username: "admin"'
  printf '  password: "%s"\n' "$ADMIN_PASSWORD"
  printf '%s\n' 'frontend:'
  printf '%s\n' '  publicApiBaseURL: "https://grok-api.zixungou.com"'
  printf '%s\n' '  staticPath: "./frontend/dist"'
  printf '%s\n' 'database:'
  printf '%s\n' '  driver: sqlite'
  printf '%s\n' '  sqlite:'
  printf '%s\n' '    path: "./data/backend.db"'
  printf '%s\n' 'runtimeStore:'
  printf '%s\n' '  driver: memory'
  printf '%s\n' 'media:'
  printf '%s\n' '  driver: local'
  printf '%s\n' '  local:'
  printf '%s\n' '    path: "./data/media"'
  printf '%s\n' 'routing:'
  printf '%s\n' '  reasoningReplayEnabled: true'
  printf '%s\n' '  reasoningReplayTTL: 1h'
  printf '%s\n' '  reasoningReplayMaxEntries: 10240'
  printf '%s\n' 'clientKeyDefaults:'
  printf '%s\n' '  rpmLimit: 30'
  printf '%s\n' '  maxConcurrent: 2'
} >"$TARGET"

{
  printf '%s\n' 'username=admin'
  printf 'password=%s\n' "$ADMIN_PASSWORD"
} >"$CREDENTIALS"

printf '%s\n' "$BACKUP_PASSWORD" >"$BACKUP_PASS"
chmod 0600 "$TARGET" "$CREDENTIALS" "$BACKUP_PASS"
echo "generated $TARGET, $CREDENTIALS and $BACKUP_PASS without printing secrets"
```

- [ ] **Step 3: Create bootstrap finalization**

Create `deploy/v3-production/finalize-bootstrap.sh`:

```sh
#!/bin/sh
set -eu
umask 077

TARGET=${1:-config.yaml}
TMP="${TARGET}.without-bootstrap"

test -f "$TARGET"
grep -q '^bootstrapAdmin:$' "$TARGET" || {
  echo 'bootstrapAdmin is already absent' >&2
  exit 1
}

awk '
  /^bootstrapAdmin:$/ { skipping = 1; next }
  /^frontend:$/ { skipping = 0 }
  !skipping { print }
' "$TARGET" >"$TMP"

grep -q '^frontend:$' "$TMP"
if grep -q '^bootstrapAdmin:$' "$TMP"; then
  echo 'failed to remove bootstrapAdmin' >&2
  exit 1
fi

chmod 0600 "$TMP"
mv "$TMP" "$TARGET"
echo 'bootstrapAdmin removed'
```

- [ ] **Step 4: Make scripts executable and validate generated config shape**

```bash
chmod +x deploy/v3-production/render-config.sh deploy/v3-production/finalize-bootstrap.sh
tmp_dir=$(mktemp -d)
deploy/v3-production/render-config.sh "$tmp_dir/config.yaml" "$tmp_dir/bootstrap-credentials.txt" "$tmp_dir/backup.pass"
grep -q '^bootstrapAdmin:$' "$tmp_dir/config.yaml"
deploy/v3-production/finalize-bootstrap.sh "$tmp_dir/config.yaml"
test "$(stat -f '%Lp' "$tmp_dir/config.yaml")" = 600
! grep -q '^bootstrapAdmin:$' "$tmp_dir/config.yaml"
```

Expected: all commands succeed; no generated secret is printed.

- [ ] **Step 5: Commit the container bundle**

```bash
git add deploy/v3-production/docker-compose.yml deploy/v3-production/render-config.sh deploy/v3-production/finalize-bootstrap.sh
git commit -m "feat: add hardened grok2api v3 container bundle"
```

## Task 3: Add the OpenResty route boundary

**Files:**
- Create: `deploy/v3-production/openresty/01-grok-api-limits.conf`
- Create: `deploy/v3-production/openresty/grok-api.root.conf`
- Create: `deploy/v3-production/openresty/grok-admin.root.conf`

- [ ] **Step 1: Define the shared API rate-limit zone**

Create `deploy/v3-production/openresty/01-grok-api-limits.conf`:

```nginx
limit_req_zone $binary_remote_addr zone=grok_api_per_ip:10m rate=60r/m;
```

- [ ] **Step 2: Define the public API allowlist**

Create `deploy/v3-production/openresty/grok-api.root.conf`:

```nginx
if ($cf_or_lan = 0) {
    return 444;
}

client_max_body_size 1m;

location = /v1/models {
    limit_except GET { deny all; }
    limit_req zone=grok_api_per_ip burst=10 nodelay;
    proxy_pass http://127.0.0.1:8998;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Port $server_port;
    proxy_connect_timeout 10s;
    proxy_send_timeout 900s;
    proxy_read_timeout 900s;
}

location = /v1/chat/completions {
    limit_except POST { deny all; }
    limit_req zone=grok_api_per_ip burst=10 nodelay;
    proxy_pass http://127.0.0.1:8998;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Port $server_port;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_cache off;
    add_header X-Accel-Buffering no always;
    proxy_connect_timeout 10s;
    proxy_send_timeout 900s;
    proxy_read_timeout 900s;
}

location / {
    return 404;
}
```

- [ ] **Step 3: Define the admin-only proxy**

Create `deploy/v3-production/openresty/grok-admin.root.conf`:

```nginx
if ($cf_or_lan = 0) {
    return 444;
}

client_max_body_size 32m;

location ^~ /v1/ {
    return 404;
}

location = /healthz {
    return 404;
}

location = /readyz {
    return 404;
}

location ^~ /swagger/ {
    return 404;
}

location / {
    proxy_pass http://127.0.0.1:8998;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Port $server_port;
    proxy_connect_timeout 10s;
    proxy_send_timeout 900s;
    proxy_read_timeout 900s;
}
```

- [ ] **Step 4: Run static proxy assertions**

```bash
grep -q 'location = /v1/models' deploy/v3-production/openresty/grok-api.root.conf
grep -q 'location = /v1/chat/completions' deploy/v3-production/openresty/grok-api.root.conf
grep -q 'proxy_buffering off' deploy/v3-production/openresty/grok-api.root.conf
grep -q 'location ^~ /v1/' deploy/v3-production/openresty/grok-admin.root.conf
```

- [ ] **Step 5: Commit the proxy boundary**

```bash
git add deploy/v3-production/openresty
git commit -m "feat: restrict grok2api production routes"
```

## Task 4: Add encrypted backup automation

**Files:**
- Create: `deploy/v3-production/backup.sh`
- Create: `deploy/v3-production/systemd/grok2api-backup.service`
- Create: `deploy/v3-production/systemd/grok2api-backup.timer`

- [ ] **Step 1: Create the consistent backup script**

Create `deploy/v3-production/backup.sh`:

```sh
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

ls -1t "$BACKUP_DIR"/daily-*.tar.enc 2>/dev/null | awk 'NR > 7' | while IFS= read -r old; do rm -f -- "$old"; done
ls -1t "$BACKUP_DIR"/weekly-*.tar.enc 2>/dev/null | awk 'NR > 4' | while IFS= read -r old; do rm -f -- "$old"; done

echo "backup created: $DAILY"
```

- [ ] **Step 2: Create the one-shot systemd unit**

Create `deploy/v3-production/systemd/grok2api-backup.service`:

```ini
[Unit]
Description=Encrypted Grok2API SQLite backup
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/opt/1panel/apps/local/grok2api/backup.sh
User=root
Group=root
PrivateTmp=true
NoNewPrivileges=true
ProtectHome=read-only
ProtectSystem=strict
ReadWritePaths=/opt/1panel/backups/grok2api
ReadOnlyPaths=/opt/1panel/apps/local/grok2api /var/lib/docker /root/.config/grok2api-backup.pass
```

- [ ] **Step 3: Create the daily timer**

Create `deploy/v3-production/systemd/grok2api-backup.timer`:

```ini
[Unit]
Description=Run Grok2API backup daily

[Timer]
OnCalendar=*-*-* 04:20:00 Asia/Shanghai
Persistent=true
RandomizedDelaySec=5m
Unit=grok2api-backup.service

[Install]
WantedBy=timers.target
```

- [ ] **Step 4: Make the backup script executable and commit**

```bash
chmod +x deploy/v3-production/backup.sh
git add deploy/v3-production/backup.sh deploy/v3-production/systemd
git commit -m "feat: add encrypted grok2api backups"
```

## Task 5: Add verification and operating documentation

**Files:**
- Create: `deploy/v3-production/verify.sh`
- Create: `deploy/v3-production/README.md`

- [ ] **Step 1: Create the public verification script**

Create `deploy/v3-production/verify.sh`:

```sh
#!/bin/sh
set -eu

: "${API_KEY:?set API_KEY in the environment}"
: "${GROK_MODEL:?set GROK_MODEL in the environment}"
API_BASE=${API_BASE:-https://grok-api.zixungou.com}

code() {
  curl -sS -o /dev/null -w '%{http_code}' "$@"
}

test "$(code "$API_BASE/v1/models")" = 401
test "$(code -H "Authorization: Bearer $API_KEY" "$API_BASE/v1/models")" = 200

for path in \
  /healthz \
  /readyz \
  /swagger/index.html \
  /api/admin/v1/auth/login \
  /v1/responses \
  /v1/messages \
  /v1/images/generations \
  /v1/images/edits \
  /v1/videos/generations
do
  test "$(code -H "Authorization: Bearer $API_KEY" "$API_BASE$path")" = 404
done

CHAT_BODY=$(mktemp)
TOOL_BODY=$(mktemp)
trap 'rm -f "$CHAT_BODY" "$TOOL_BODY"' EXIT HUP INT TERM

printf '{"model":"%s","stream":false,"messages":[{"role":"user","content":"Reply with exactly: ok"}]}' "$GROK_MODEL" >"$CHAT_BODY"
test "$(code -X POST -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' --data-binary "@$CHAT_BODY" "$API_BASE/v1/chat/completions")" = 200

printf '{"model":"%s","stream":false,"messages":[{"role":"user","content":"Call the weather tool for Shanghai."}],"tools":[{"type":"function","function":{"name":"weather","description":"Get weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],"tool_choice":"required"}' "$GROK_MODEL" >"$TOOL_BODY"
test "$(code -X POST -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' --data-binary "@$TOOL_BODY" "$API_BASE/v1/chat/completions")" = 200

echo 'public grok2api verification passed'
```

- [ ] **Step 2: Write the operating README**

Create `deploy/v3-production/README.md` with these exact commands and rules:

````markdown
# Grok2API v3 production bundle

Production directory: `/opt/1panel/apps/local/grok2api`

## Start and inspect

```bash
cd /opt/1panel/apps/local/grok2api
docker compose pull
docker compose up -d
docker compose ps
curl -fsS http://127.0.0.1:8998/healthz
curl -fsS http://127.0.0.1:8998/readyz
```

## Logs

```bash
docker compose logs --since=30m --no-color grok2api
docker inspect grok2api-v3 --format '{{.RestartCount}} {{.State.OOMKilled}}'
```

Never print `config.yaml`, `bootstrap-credentials.txt`, `backup.pass`, API keys, cookies, or imported account files into automation logs.

## Upgrade

1. Run and verify an encrypted backup.
2. Read the upstream release notes.
3. Resolve and record the linux/amd64 image digest.
4. Update both version and digest in `docker-compose.yml`.
5. Pull and recreate only `grok2api`.
6. Verify health, admin login, model list, chat, tools, and search.

## Rollback

Rollback the image and SQLite database together. Never run an older image against a database migrated by a newer release.

```bash
cd /opt/1panel/apps/local/grok2api
docker compose stop grok2api
```

Decrypt the matching backup into an isolated directory, verify `PRAGMA integrity_check`, restore `config.yaml` and `backend.db`, restore the previous image digest, then start and run the complete verification matrix.

## Backups

```bash
systemctl start grok2api-backup.service
systemctl status grok2api-backup.service --no-pager
systemctl list-timers grok2api-backup.timer --no-pager
```
````

- [ ] **Step 3: Run the full bundle test**

```bash
chmod +x deploy/v3-production/verify.sh
deploy/v3-production/test-bundle.sh
```

Expected: `deployment bundle checks passed`.

- [ ] **Step 4: Check formatting and secrets**

```bash
git diff --check
rg -n -g '!test-bundle.sh' '(sso=[^[:space:]]+|g2a_[A-Za-z0-9]{16,}|BEGIN.*PRIVATE KEY|credentialEncryptionKey: "[A-Za-z0-9+/=]{40,}"|jwtSecret: "[A-Fa-f0-9]{64}")' deploy/v3-production
```

Expected: `git diff --check` succeeds and `rg` returns no matches.

- [ ] **Step 5: Commit the operating bundle**

```bash
git add deploy/v3-production/verify.sh deploy/v3-production/README.md
git commit -m "docs: add grok2api production runbook"
```

## Task 6: Perform the remote preflight without changing services

**Files:**
- Inspect remotely: `/opt/1panel/apps/local`
- Inspect remotely: `/opt/1panel/www/conf.d`

- [ ] **Step 1: Capture the current server baseline**

Run:

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  date -Is
  uname -a
  free -h
  df -h /
  docker ps --format "{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}"
  ss -lntup
  ufw status verbose
'
```

Expected: existing zixungou containers remain up; `127.0.0.1:8998` is unused; UFW exposes no new Grok2API port.

- [ ] **Step 2: Verify DNS and Cloudflare proxying**

Run locally:

```bash
dig +short grok-api.zixungou.com
dig +short grok-admin.zixungou.com
```

Expected: both return Cloudflare anycast addresses rather than `45.32.46.142` directly.

- [ ] **Step 3: Reclaim only unused build cache**

Run:

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  docker system df
  docker builder prune --force --filter until=168h
  df -h /
'
```

Expected: root filesystem usage is at or below 75%. Do not run image or volume prune.

- [ ] **Step 4: Verify required host tools**

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  command -v docker
  command -v openssl
  command -v python3
  command -v systemctl
  test -f /opt/1panel/www/conf.d/00-cloudflare-realip.conf
'
```

Expected: all commands succeed.

## Task 7: Install and start the loopback-only application

**Files:**
- Create remotely: `/opt/1panel/apps/local/grok2api/docker-compose.yml`
- Create remotely: `/opt/1panel/apps/local/grok2api/render-config.sh`
- Create remotely: `/opt/1panel/apps/local/grok2api/finalize-bootstrap.sh`
- Create remotely: `/opt/1panel/apps/local/grok2api/backup.sh`
- Create remotely: `/root/.config/grok2api-backup.pass`

- [ ] **Step 1: Create remote directories**

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  install -d -m 0700 /opt/1panel/apps/local/grok2api
  install -d -m 0700 /opt/1panel/backups/grok2api
  install -d -m 0700 /root/.config
'
```

- [ ] **Step 2: Copy only the required deployment files**

```bash
scp -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 \
  deploy/v3-production/docker-compose.yml \
  deploy/v3-production/render-config.sh \
  deploy/v3-production/finalize-bootstrap.sh \
  deploy/v3-production/backup.sh \
  root@45.32.46.142:/opt/1panel/apps/local/grok2api/
```

- [ ] **Step 3: Generate server-only secrets**

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  cd /opt/1panel/apps/local/grok2api
  chmod 0700 render-config.sh finalize-bootstrap.sh backup.sh
  ./render-config.sh config.yaml bootstrap-credentials.txt /root/.config/grok2api-backup.pass
  test "$(stat -c %a config.yaml)" = 600
  test "$(stat -c %a bootstrap-credentials.txt)" = 600
  test "$(stat -c %a /root/.config/grok2api-backup.pass)" = 600
'
```

Expected: generated file paths are reported but no secret values are printed. The user reads `bootstrap-credentials.txt` directly in their own trusted SSH or 1Panel session, never through agent logs.

- [ ] **Step 4: Pull and start only Grok2API**

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  cd /opt/1panel/apps/local/grok2api
  docker compose pull
  docker compose up -d
  docker compose ps
'
```

Expected: `grok2api-v3` is healthy; no existing container is recreated.

- [ ] **Step 5: Verify runtime isolation**

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  curl -fsS http://127.0.0.1:8998/healthz
  ss -lntp | grep "127.0.0.1:8998"
  ! ss -lntp | grep -E "0.0.0.0:8998|\[::\]:8998"
  docker inspect grok2api-v3 --format "{{.Config.User}}|{{.HostConfig.Memory}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.PidsLimit}}|{{json .HostConfig.CapDrop}}|{{json .HostConfig.CapAdd}}"
  docker stats --no-stream grok2api-v3
'
```

Expected: health is OK; only loopback port 8998 exists; memory is 402653184 bytes; CPU is 750000000 NanoCPUs; PID limit is 128.

## Task 8: Configure Cloudflare Access and initialize Admin

**Files:**
- Modify remotely: `/opt/1panel/apps/local/grok2api/config.yaml`

- [ ] **Step 1: Create the Cloudflare Access application**

In Cloudflare Zero Trust:

1. Create a self-hosted application for `grok-admin.zixungou.com`.
2. Add one Allow policy containing only the administrator email.
3. Require the configured identity provider or email one-time PIN.
4. Set the Access session duration to 8 hours.
5. Leave `grok-api.zixungou.com` outside Access.

Expected: an unauthenticated browser is stopped by Cloudflare Access before the origin responds.

- [ ] **Step 2: Create both 1Panel HTTPS sites without proxy fragments yet**

In 1Panel, create reverse-proxy websites for:

- `grok-api.zixungou.com`
- `grok-admin.zixungou.com`

Issue certificates and keep the proxy target temporarily disabled until Task 10 installs the route fragments.

- [ ] **Step 3: Log into Admin through a temporary SSH tunnel**

Keep the public proxy disabled. In a trusted local terminal, open a loopback-only tunnel:

```bash
ssh -N -L 18998:127.0.0.1:8998 -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142
```

The user retrieves `/opt/1panel/apps/local/grok2api/bootstrap-credentials.txt` in a separate trusted SSH session, opens `http://127.0.0.1:18998`, and logs in. Close the tunnel immediately after bootstrap and account configuration.

Expected: application Admin login succeeds locally while neither public hostname can reach the application origin yet.

- [ ] **Step 4: Change the Admin password and remove bootstrap configuration**

After the user changes the password in Admin, run:

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  cd /opt/1panel/apps/local/grok2api
  ./finalize-bootstrap.sh config.yaml
  docker compose up -d --force-recreate grok2api
  grep -q "^frontend:$" config.yaml
  ! grep -q "^bootstrapAdmin:$" config.yaml
  shred -u bootstrap-credentials.txt
'
```

Expected: the new Admin password still works after restart and the bootstrap credential file is removed.

## Task 9: Import accounts and constrain model access

**Files:**
- Create temporarily: `/tmp/grok-web-sso.txt` on the local Mac
- Modify through Admin: accounts, model routes, client keys, runtime settings

- [ ] **Step 1: Export the old Web SSO tokens to a local protected file**

Run locally from the old Python deployment directory:

```bash
umask 077
sqlite3 data/accounts.db "SELECT token FROM accounts WHERE status = 'active' AND deleted_at IS NULL ORDER BY rowid;" > /tmp/grok-web-sso.txt
test -s /tmp/grok-web-sso.txt
test "$(stat -f '%Lp' /tmp/grok-web-sso.txt)" = 600
```

Expected: the command prints no token; the file is readable only by the local user.

- [ ] **Step 2: Import through the Web Provider import page**

In Admin, choose Grok Web account import and upload `/tmp/grok-web-sso.txt`.

Expected: accounts are created or updated, credential sync completes, and the Admin never displays full stored tokens afterward.

- [ ] **Step 3: Verify Statsig and account readiness**

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  curl -fsS http://127.0.0.1:8998/readyz
  docker compose -f /opt/1panel/apps/local/grok2api/docker-compose.yml logs --since=15m --no-color grok2api | grep -E "statsig|startup|ready" | tail -n 80
'
```

Expected: at least one provider is ready; Web Statsig is `warm` or a documented temporary `degraded`, with no credential values in logs.

- [ ] **Step 4: Enable only Chat model routes**

In Admin model routing:

- Enable only the Chat models required by the user.
- Disable all image, image-edit, video, Anthropic-only, Responses-only, and media routes.
- Confirm `GET /v1/models` lists no image or video model.

- [ ] **Step 5: Create isolated client keys**

In Admin:

- Create one key per same-machine service at 30 RPM and concurrency 2.
- Create one personal key at 60 RPM and concurrency 4.
- Assign only the enabled Chat model IDs to every key.
- Store each secret directly in its consuming service's secret store; do not paste it into repository files.

- [ ] **Step 6: Remove the temporary token export**

```bash
rm -P /tmp/grok-web-sso.txt
```

Expected: the plaintext migration file no longer exists.

## Task 10: Install and activate the OpenResty boundary

**Files:**
- Create remotely: `/opt/1panel/www/conf.d/01-grok-api-limits.conf`
- Replace remotely: `/opt/1panel/www/sites/grok-api/proxy/root.conf`
- Replace remotely: `/opt/1panel/www/sites/grok-admin/proxy/root.conf`

- [ ] **Step 1: Back up current generated site files**

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  install -d -m 0700 /opt/1panel/backups/grok2api/openresty-predeploy
  cp -a /opt/1panel/www/conf.d/grok-api.conf /opt/1panel/backups/grok2api/openresty-predeploy/
  cp -a /opt/1panel/www/conf.d/grok-admin.conf /opt/1panel/backups/grok2api/openresty-predeploy/
'
```

- [ ] **Step 2: Copy the reviewed route fragments**

```bash
scp -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 \
  deploy/v3-production/openresty/01-grok-api-limits.conf \
  root@45.32.46.142:/opt/1panel/www/conf.d/01-grok-api-limits.conf

scp -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 \
  deploy/v3-production/openresty/grok-api.root.conf \
  root@45.32.46.142:/opt/1panel/www/sites/grok-api/proxy/root.conf

scp -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 \
  deploy/v3-production/openresty/grok-admin.root.conf \
  root@45.32.46.142:/opt/1panel/www/sites/grok-admin/proxy/root.conf
```

- [ ] **Step 3: Test syntax before reload**

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  docker exec 1Panel-openresty-YL43 openresty -t
'
```

Expected: `syntax is ok` and `test is successful`. If not, restore the three saved files and do not reload.

- [ ] **Step 4: Reload OpenResty and test local TLS routing**

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  docker exec 1Panel-openresty-YL43 openresty -s reload
  curl -k -sS --resolve grok-api.zixungou.com:443:127.0.0.1 -o /dev/null -w "%{http_code}\n" https://grok-api.zixungou.com/v1/models
  curl -k -sS --resolve grok-api.zixungou.com:443:127.0.0.1 -o /dev/null -w "%{http_code}\n" https://grok-api.zixungou.com/v1/responses
'
```

Expected: models returns 401 without a key; Responses returns 404.

- [ ] **Step 5: Verify origin bypass is rejected from the local Mac**

```bash
curl -k --resolve grok-api.zixungou.com:443:45.32.46.142 -o /dev/null -w '%{http_code}\n' https://grok-api.zixungou.com/v1/models
curl -k --resolve grok-admin.zixungou.com:443:45.32.46.142 -o /dev/null -w '%{http_code}\n' https://grok-admin.zixungou.com/
```

Expected: both direct-origin requests fail with an empty reply or non-success result caused by Nginx 444.

## Task 11: Run the public acceptance matrix

**Files:**
- Verify: `deploy/v3-production/verify.sh`

- [ ] **Step 1: Run automated public API checks**

Set the personal API key and one enabled model in the local shell without writing them to disk:

```bash
read -s API_KEY
export API_KEY
read GROK_MODEL
export GROK_MODEL
deploy/v3-production/verify.sh
unset API_KEY GROK_MODEL
```

Expected: `public grok2api verification passed`.

- [ ] **Step 2: Verify SSE is not buffered**

Run with the same environment variables:

```bash
curl -N -sS https://grok-api.zixungou.com/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$GROK_MODEL\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Count from one to five slowly.\"}]}"
```

Expected: multiple SSE chunks arrive before the terminal `[DONE]` event.

- [ ] **Step 3: Verify search**

```bash
curl -sS https://grok-api.zixungou.com/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$GROK_MODEL\",\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"Search the web for the current UTC date and cite the sources you used.\"}]}"
```

Expected: HTTP 200 with a text answer and search-source metadata or citations.

- [ ] **Step 4: Verify body and rate boundaries**

```bash
dd if=/dev/zero bs=1048577 count=1 2>/dev/null | \
  curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST https://grok-api.zixungou.com/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  --data-binary @-
```

Expected: 413.

- [ ] **Step 5: Scan recent logs for secret-shaped values**

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  docker compose -f /opt/1panel/apps/local/grok2api/docker-compose.yml logs --since=30m --no-color grok2api > /tmp/grok2api-recent.log
  ! grep -E "sso=|Authorization: Bearer|g2a_[A-Za-z0-9]{16,}|credentialEncryptionKey|jwtSecret" /tmp/grok2api-recent.log
  rm -f /tmp/grok2api-recent.log
'
```

Expected: no secret-shaped log entry is found.

## Task 12: Enable backups, prove rollback assets, and observe stability

**Files:**
- Install remotely: `/etc/systemd/system/grok2api-backup.service`
- Install remotely: `/etc/systemd/system/grok2api-backup.timer`

- [ ] **Step 1: Install the backup units**

```bash
scp -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 \
  deploy/v3-production/systemd/grok2api-backup.service \
  deploy/v3-production/systemd/grok2api-backup.timer \
  root@45.32.46.142:/etc/systemd/system/

ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  systemctl daemon-reload
  systemctl enable --now grok2api-backup.timer
  systemctl start grok2api-backup.service
  systemctl status grok2api-backup.service --no-pager
  systemctl list-timers grok2api-backup.timer --no-pager
'
```

Expected: backup service exits successfully and the timer has a next run.

- [ ] **Step 2: Decrypt and integrity-check a backup without restoring it**

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  set -eu
  latest=$(ls -1t /opt/1panel/backups/grok2api/daily-*.tar.enc | head -n 1)
  check_dir=$(mktemp -d /opt/1panel/backups/grok2api/.restore-check.XXXXXX)
  trap "rm -rf $check_dir" EXIT
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass file:/root/.config/grok2api-backup.pass -in "$latest" | tar -C "$check_dir" -xf -
  python3 - "$check_dir/backend.db" <<"PY"
import sqlite3
import sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
result = db.execute("PRAGMA integrity_check").fetchone()[0]
db.close()
if result != "ok":
    raise SystemExit(result)
print("backup database integrity ok")
PY
'
```

Expected: `backup database integrity ok`; production files are untouched.

- [ ] **Step 3: Record rollback identifiers**

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  docker inspect grok2api-v3 --format "image={{.Image}}"
  sha256sum /opt/1panel/apps/local/grok2api/docker-compose.yml
  ls -1t /opt/1panel/backups/grok2api/daily-*.tar.enc | head -n 1
'
```

Expected: image ID, Compose checksum, and matching backup filename are recorded in the deployment handoff without secret contents.

- [ ] **Step 4: Observe for 24 hours**

At the beginning and end of the observation window, run:

```bash
ssh -i ~/.ssh/vultr_migrate_2026_03_20_ed25519 root@45.32.46.142 '
  date -Is
  docker stats --no-stream grok2api-v3
  docker inspect grok2api-v3 --format "restarts={{.RestartCount}} oom={{.State.OOMKilled}} status={{.State.Status}}"
  df -h /
  curl -fsS http://127.0.0.1:8998/readyz
  docker compose -f /opt/1panel/apps/local/grok2api/docker-compose.yml logs --since=24h --no-color grok2api | grep -Ec "403|429|statsig.*failed|panic|fatal" || true
'
```

Expected after 24 hours: no OOM, no unexpected restart, disk growth is bounded, at least one provider is ready, and Statsig is not persistently degraded.

- [ ] **Step 5: Final verification and handoff commit**

```bash
deploy/v3-production/test-bundle.sh
git status --short
git log -5 --oneline
```

Expected: deployment bundle passes; only pre-existing unrelated local changes remain; all deployment assets and documentation are committed.
