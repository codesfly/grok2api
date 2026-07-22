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
