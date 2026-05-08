#!/usr/bin/env bash
# Dragline SQLite backup script
#
# Usage: backup.sh <instance>
#   instance — the systemd instance identifier, e.g. "1" or "prod"
#
# The script reads DRAGLINE_DB from the instance environment file.
# Backups are compressed with gzip and stored in BACKUP_DIR.
# Backups older than 30 days are deleted automatically.
#
# Schedule this script via cron, e.g. to run daily at 02:00:
#   0 2 * * * /opt/dragline/deploy/backup.sh 1 >> /var/log/dragline-backup.log 2>&1

set -euo pipefail

# ------------------------------------------------------------------ configuration
# Adjust BACKUP_DIR to wherever you want backups stored.
BACKUP_DIR="/var/backups/dragline"
RETENTION_DAYS=30

# ------------------------------------------------------------------ validation
if [[ $# -lt 1 || -z "${1:-}" ]]; then
    echo "Usage: $0 <instance>" >&2
    echo "  Example: $0 1" >&2
    exit 1
fi

INSTANCE="$1"

if ! [[ "$INSTANCE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: instance identifier must be alphanumeric (got: '$INSTANCE')" >&2
    exit 1
fi

ENV_FILE="/etc/dragline/${INSTANCE}.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: environment file not found: $ENV_FILE" >&2
    exit 1
fi

# ------------------------------------------------------------------ read database path
# Source the env file to pick up DRAGLINE_DB.
# Only export variables we trust; the env file may contain secrets.
DRAGLINE_DB=""
while IFS='=' read -r key value; do
    # Skip blank lines and comments
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    key="${key// /}"
    if [[ "$key" == "DRAGLINE_DB" ]]; then
        # Strip surrounding quotes if present
        DRAGLINE_DB="${value//\"/}"
        DRAGLINE_DB="${DRAGLINE_DB//\'/}"
    fi
done < "$ENV_FILE"

if [[ -z "$DRAGLINE_DB" ]]; then
    echo "Error: DRAGLINE_DB not set in $ENV_FILE" >&2
    exit 1
fi

if [[ ! -f "$DRAGLINE_DB" ]]; then
    echo "Error: database file not found: $DRAGLINE_DB" >&2
    exit 1
fi

# ------------------------------------------------------------------ backup
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="dragline_${INSTANCE}_backup_${TIMESTAMP}.db"
TMP_PATH="/tmp/${BACKUP_NAME}"

mkdir -p "$BACKUP_DIR"

echo "[$(date --iso-8601=seconds)] Starting backup of ${DRAGLINE_DB} (instance ${INSTANCE})"

# sqlite3 .backup is a hot backup — safe to run while the app is live.
sqlite3 "$DRAGLINE_DB" ".backup ${TMP_PATH}"

echo "[$(date --iso-8601=seconds)] Backup written to ${TMP_PATH}, compressing..."

gzip "$TMP_PATH"

COMPRESSED_PATH="${TMP_PATH}.gz"
DEST_PATH="${BACKUP_DIR}/${BACKUP_NAME}.gz"

mv "$COMPRESSED_PATH" "$DEST_PATH"

echo "[$(date --iso-8601=seconds)] Backup stored at ${DEST_PATH}"

# ------------------------------------------------------------------ prune old backups
echo "[$(date --iso-8601=seconds)] Pruning backups older than ${RETENTION_DAYS} days from ${BACKUP_DIR}"

PRUNED=0
while IFS= read -r -d '' old_backup; do
    rm -f "$old_backup"
    echo "[$(date --iso-8601=seconds)] Deleted old backup: ${old_backup}"
    PRUNED=$((PRUNED + 1))
done < <(find "$BACKUP_DIR" -maxdepth 1 -name "dragline_${INSTANCE}_backup_*.db.gz" \
         -mtime +"$RETENTION_DAYS" -print0)

echo "[$(date --iso-8601=seconds)] Pruned ${PRUNED} old backup(s)."

# ------------------------------------------------------------------ done
echo "[$(date --iso-8601=seconds)] Backup complete for instance '${INSTANCE}'."
