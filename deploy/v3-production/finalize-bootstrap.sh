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
