#!/usr/bin/env bash
# One-command setup on a fresh Ubuntu 24.04 server (run as root from /opt/sixthsense):
#
#   bash deploy/install.sh api.example.com insight.example.com
#
# Safe to run again (it keeps an existing .env and CompreFace key).
set -euo pipefail
API_DOMAIN=${1:?usage: install.sh API_DOMAIN INSIGHT_DOMAIN}
INSIGHT_DOMAIN=${2:?usage: install.sh API_DOMAIN INSIGHT_DOMAIN}
ROOT=/opt/sixthsense
cd "$ROOT"
export DEBIAN_FRONTEND=noninteractive PATH=/root/.local/bin:$PATH
COMPOSE="docker compose --env-file .env -f infra/docker-compose.yml -f deploy/docker-compose.server.yml"

echo "== 1/7 packages"
apt-get update -qq
apt-get install -y -qq git curl ca-certificates docker.io docker-compose-v2 caddy python3 >/dev/null
systemctl enable --now docker >/dev/null
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null

echo "== 2/7 firewall (Ubuntu images often only allow SSH)"
if ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null
fi

echo "== 3/7 .env"
[ -f .env ] || python3 deploy/make_env.py "$API_DOMAIN" "$INSIGHT_DOMAIN"

echo "== 4/7 databases, Redis, NATS, CompreFace (localhost only)"
$COMPOSE up -d --wait core-db insight-db redis nats mailpit
$COMPOSE up -d compreface
grep -q '^COMPREFACE_API_KEY=.' .env || bash deploy/setup_compreface.sh

echo "== 5/7 Python dependencies and database tables"
(cd backend && uv sync -q --no-dev && uv run --no-dev alembic upgrade head)
(cd insight && uv sync -q --no-dev && uv run --no-dev alembic upgrade head)

echo "== 6/7 services"
cp deploy/systemd/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable sixthsense-core sixthsense-worker sixthsense-insight >/dev/null 2>&1
systemctl restart sixthsense-core sixthsense-worker sixthsense-insight

echo "== 7/7 HTTPS"
sed -e "s/API_DOMAIN/$API_DOMAIN/" -e "s/INSIGHT_DOMAIN/$INSIGHT_DOMAIN/" \
  deploy/Caddyfile.example > /etc/caddy/Caddyfile
systemctl reload caddy || systemctl restart caddy

sleep 30
for host in "$API_DOMAIN" "$INSIGHT_DOMAIN"; do
  echo "https://$host/healthz -> $(curl -s --max-time 20 "https://$host/healthz" || echo 'not ready yet (certificate may take a minute)')"
done
echo
echo "Done. Next: put your Gmail (SMTP_*) and Telegram (TELEGRAM_*) values in $ROOT/.env, then"
echo "  systemctl restart sixthsense-core sixthsense-worker"
