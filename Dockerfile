# ── Builder ───────────────────────────────────────────────────────────────────
# glibc (Debian) base: SQLite WAL works, and all deps ship manylinux wheels so
# no Rust/C toolchain is needed. musl/Alpine forced source builds and, after the
# sqlite-libs 3.53 bump, broke SQLite WAL (disk I/O error on journal_mode=WAL).
FROM python:3.13-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_PROJECT_ENVIRONMENT=/opt/venv

ENV PATH="$UV_PROJECT_ENVIRONMENT/bin:$PATH"

WORKDIR /app

# Pin uv to a minor version for reproducible builds.
# Bump manually when you want to pick up a newer uv release.
COPY --from=ghcr.io/astral-sh/uv:0.6 /uv /uvx /bin/

COPY pyproject.toml uv.lock ./

RUN uv sync --frozen --no-dev --no-install-project \
    && find /opt/venv -type d \
         \( -name "__pycache__" -o -name "tests" -o -name "test" -o -name "testing" \) \
         -prune -exec rm -rf {} + \
    && find /opt/venv -type f -name "*.pyc" -delete \
    && rm -rf /root/.cache /tmp/uv-cache

# ── Runtime ───────────────────────────────────────────────────────────────────
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai \
    VIRTUAL_ENV=/opt/venv \
    SERVER_HOST=0.0.0.0 \
    SERVER_PORT=8000 \
    SERVER_WORKERS=1

ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv

COPY pyproject.toml config.defaults.toml ./
COPY app ./app
COPY scripts ./scripts

RUN mkdir -p /app/data /app/logs \
    && chmod +x /app/scripts/entrypoint.sh /app/scripts/init_storage.sh

EXPOSE 8000

# python-based healthcheck (Debian slim has no wget).
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["python", "-c", "import os,sys,urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:'+os.environ['SERVER_PORT']+'/health', timeout=4).status==200 else 1)"]

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD ["sh", "-c", "exec granian --interface asgi --host ${SERVER_HOST} --port ${SERVER_PORT} --workers ${SERVER_WORKERS} app.main:app"]
