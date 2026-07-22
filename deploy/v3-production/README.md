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
