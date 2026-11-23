#!/usr/bin/env bash
set -euo pipefail

: "${SERVER_HOST:?Set SERVER_HOST in your local environment}"
: "${REMOTE_DIR:?Set the absolute REMOTE_DIR on the server}"
STANDBY_DIR="${STANDBY_DIR:-$HOME/tripscript-backend-standby}"

echo "[TripScript] Creating a consistent SQLite backup on $SERVER_HOST..."
ssh "$SERVER_HOST" "cd '$REMOTE_DIR' && docker compose exec -T api python - <<'PY'
import sqlite3
from pathlib import Path

storage = Path('storage')
storage.mkdir(exist_ok=True)
source = storage / 'tripscript.db'
backup = storage / 'tripscript.db.server-backup'

src = sqlite3.connect(source)
dst = sqlite3.connect(backup)
with dst:
    src.backup(dst)
src.close()
dst.close()
print(backup)
PY"

echo "[TripScript] Syncing backend runtime snapshot to $STANDBY_DIR..."
mkdir -p "$STANDBY_DIR"
rsync -az --delete \
  --exclude '.git/' \
  --exclude '__pycache__/' \
  --exclude '.pytest_cache/' \
  --exclude 'admin_web/node_modules/' \
  --exclude 'admin_web/dist/' \
  "$SERVER_HOST:$REMOTE_DIR/" "$STANDBY_DIR/"

if [[ -f "$STANDBY_DIR/storage/tripscript.db.server-backup" ]]; then
  cp "$STANDBY_DIR/storage/tripscript.db.server-backup" "$STANDBY_DIR/storage/tripscript.db"
fi

echo "[TripScript] Backup complete."
echo "  Standby dir: $STANDBY_DIR"
echo "  Do not start this standby while the server computer ngrok container is still running."
