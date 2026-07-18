#!/bin/bash
# Mus Online Database Backup Script
# Backs up the SQLite database and keeps last 7 days

BACKUP_DIR="/opt/backups"
DB_PATH="/opt/mus-online/server/players.db"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/players-$TIMESTAMP.db"

# Create backup
if [ -f "$DB_PATH" ]; then
    sqlite3 "$DB_PATH" ".backup '$BACKUP_FILE'"
    echo "Database backed up to: $BACKUP_FILE"

    # Delete backups older than 7 days
    find "$BACKUP_DIR" -name "players-*.db" -mtime +7 -delete
    echo "Old backups cleaned up"
else
    echo "Database not found at $DB_PATH"
    exit 1
fi
