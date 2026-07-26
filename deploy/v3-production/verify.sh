#!/bin/sh
set -eu

: "${API_KEY:?set API_KEY in the environment}"
: "${GROK_MODEL:?set GROK_MODEL in the environment}"
API_BASE=${API_BASE:-https://grok-api.zixungou.com}

code() {
  curl -sS -o /dev/null -w '%{http_code}' "$@"
}

expect_denied() {
  denied_code=$(code "$@")
  case "$denied_code" in
    403|404) ;;
    *)
      echo "expected a denied response (403 or 404), got $denied_code" >&2
      return 1
      ;;
  esac
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
  expect_denied -H "Authorization: Bearer $API_KEY" "$API_BASE$path"
done

CHAT_BODY=$(mktemp)
TOOL_BODY=$(mktemp)
trap 'rm -f "$CHAT_BODY" "$TOOL_BODY"' EXIT HUP INT TERM

printf '{"model":"%s","stream":false,"messages":[{"role":"user","content":"Reply with exactly: ok"}]}' "$GROK_MODEL" >"$CHAT_BODY"
test "$(code -X POST -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' --data-binary "@$CHAT_BODY" "$API_BASE/v1/chat/completions")" = 200

printf '{"model":"%s","stream":false,"messages":[{"role":"user","content":"Call the weather tool for Shanghai."}],"tools":[{"type":"function","function":{"name":"weather","description":"Get weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],"tool_choice":"required"}' "$GROK_MODEL" >"$TOOL_BODY"
test "$(code -X POST -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' --data-binary "@$TOOL_BODY" "$API_BASE/v1/chat/completions")" = 200

echo 'public grok2api verification passed'
