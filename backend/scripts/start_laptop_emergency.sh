#!/usr/bin/env bash
set -euo pipefail

STANDBY_DIR="${STANDBY_DIR:-$HOME/tripscript-backend-standby}"
: "${PUBLIC_HEALTH_URL:?Set PUBLIC_HEALTH_URL in your local environment}"
DOCKER_BIN="${DOCKER_BIN:-}"

if [[ -z "$DOCKER_BIN" ]]; then
  if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
    DOCKER_BIN="docker"
  elif [[ -x "/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe" ]]; then
    DOCKER_BIN="/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe"
  else
    echo "[TripScript] Docker was not found."
    echo "Install/start Docker Desktop or enable WSL integration, then retry."
    exit 1
  fi
fi

if [[ ! -d "$STANDBY_DIR" ]]; then
  echo "[TripScript] Standby directory not found: $STANDBY_DIR"
  echo "Run scripts/backup_server_to_laptop.sh first."
  exit 1
fi

if [[ "${CONFIRM_SERVER_NGROK_DOWN:-}" != "1" ]]; then
  cat <<'MSG'
[TripScript] Refusing to start automatically.

This standby uses the same fixed ngrok domain as the server computer.
Start it only after the server computer's ngrok container is definitely down.

Run:
  CONFIRM_SERVER_NGROK_DOWN=1 scripts/start_laptop_emergency.sh
MSG
  exit 2
fi

cd "$STANDBY_DIR"

if [[ -f storage/tripscript.db.server-backup ]]; then
  cp storage/tripscript.db.server-backup storage/tripscript.db
fi

echo "[TripScript] Starting laptop emergency backend..."
"$DOCKER_BIN" compose build api
"$DOCKER_BIN" compose up -d api redis
"$DOCKER_BIN" compose -f docker-compose.yml -f docker-compose.ngrok.yml up -d ngrok

echo "[TripScript] Waiting for local health..."
for _ in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:8000/health >/dev/null; then
    break
  fi
  sleep 1
done

curl -fsS http://127.0.0.1:8000/health
echo
echo "[TripScript] Public health check:"
curl -fsS "$PUBLIC_HEALTH_URL" || true
echo
echo "[TripScript] Emergency backend is up."
