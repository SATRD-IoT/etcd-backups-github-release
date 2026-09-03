#!/bin/bash

# Directory containing the etcd snapshots
SNAPSHOT_DIR="/data/etcd-backup/"

# Log file for the script
LOG_FILE="/data/etcd-backup/etcd_backups_cleanup.log"

# Retention period in days
RETENTION_DAYS=3

# Get the current date in seconds since epoch
CURRENT_DATE=$(date +%s)

# Log start message
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting snapshot cleanup." >> "$LOG_FILE"

# Find and delete snapshots older than the retention period
find "$SNAPSHOT_DIR" -type f -name 'etcd-snapshot-*.db' | while read -r file; do
    # Extract the date from the filename (format: etcd-snapshot-YYYY-MM-DDTHH:MM.db)
    FILE_DATE=$(basename "$file" | sed -E 's/etcd-snapshot-([0-9]{4}-[0-9]{2}-[0-9]{2})T.*/\1/')

    # Convert the file date to seconds since epoch
    FILE_DATE_EPOCH=$(date -d "$FILE_DATE" +%s 2>/dev/null)

    # Calculate the age of the snapshot in days
    if [[ -n "$FILE_DATE_EPOCH" ]]; then
        AGE=$(( (CURRENT_DATE - FILE_DATE_EPOCH) / 86400 ))

        # Delete the file if it's older than the retention period
        if [[ $AGE -gt $RETENTION_DAYS ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deleting old snapshot: $file" >> "$LOG_FILE"
            rm -f "$file"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Retaining snapshot: $file" >> "$LOG_FILE"
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error processing file: $file" >> "$LOG_FILE"
    fi
done

# Log completion message
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Snapshot cleanup completed." >> "$LOG_FILE"