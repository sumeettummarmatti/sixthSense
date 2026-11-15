#!/usr/bin/env bash
# Create the CompreFace admin, an app and a Face Verification service, and put the service's
# API key into .env as COMPREFACE_API_KEY. Run from the repo root after CompreFace is up.
# The admin login is saved to /root/compreface-admin.txt (owner-only).
set -euo pipefail
cd "$(dirname "$0")/.."

BASE=http://localhost:8003/admin
CREDS=/root/compreface-admin.txt
JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT

echo "Waiting for CompreFace..."
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/status")" = "200" ] && break
  sleep 5
done

if [ ! -f "$CREDS" ]; then
  printf 'email=admin@sixthsense.local\npassword=%s\n' \
    "$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')" > "$CREDS"
  chmod 600 "$CREDS"
fi
EMAIL=$(grep '^email=' "$CREDS" | cut -d= -f2-)
PASS=$(grep '^password=' "$CREDS" | cut -d= -f2-)

curl -s -o /dev/null -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"firstName\":\"Sixth\",\"lastName\":\"Sense\",\"isAllowStatistics\":false}" \
  "$BASE/user/register" || true
# CompreFace 1.2 keeps the admin session in a cookie.
curl -s -o /dev/null -c "$JAR" -u CommonClientId:password \
  -d "grant_type=password&username=$EMAIL&password=$PASS" "$BASE/oauth/token"
APP=$(curl -s -b "$JAR" -H 'Content-Type: application/json' -d '{"name":"sixthsense"}' \
  "$BASE/app" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
KEY=$(curl -s -b "$JAR" -H 'Content-Type: application/json' \
  -d '{"name":"face-verification","type":"VERIFY"}' "$BASE/app/$APP/model" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["apiKey"])')

sed -i "s|^COMPREFACE_API_KEY=.*|COMPREFACE_API_KEY=$KEY|" .env
echo "CompreFace ready; COMPREFACE_API_KEY saved in .env."
