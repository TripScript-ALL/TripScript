#!/usr/bin/env bash
set -euo pipefail

STANDBY_DIR="${STANDBY_DIR:-$HOME/tripscript-backend-standby}"
DOCKER_BIN="${DOCKER_BIN:-}"

if [[ -z "$DOCKER_BIN" ]]; then
  if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
    DOCKER_BIN="docker"
  elif [[ -x "/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe" ]]; then
    DOCKER_BIN="/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe"
  else
    echo "[TripScript] Docker was not found; nothing to stop from this script."
    exit 0
  fi
fi

if [[ ! -d "$STANDBY_DIR" ]]; then
  echo "[TripScript] Standby directory not found: $STANDBY_DIR"
  exit 0
fi

cd "$STANDBY_DIR"
echo "[TripScript] Stopping laptop emergency backend..."
"$DOCKER_BIN" compose -f docker-compose.yml -f docker-compose.ngrok.yml down
echo "[TripScript] Stopped."
