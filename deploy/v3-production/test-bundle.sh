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
