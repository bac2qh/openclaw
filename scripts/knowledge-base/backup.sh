#!/bin/bash
# Backup Script for Personal Knowledge Base
#
# Creates timestamped backups of OpenClaw config, memory, and transcripts.
#
# Usage: USER_PROFILE=xin ./backup.sh [destination]
#
# Environment variables:
#   USER_PROFILE - User profile name (default: xin)
#
# Default destination: ~/backups/openclaw-{USER_PROFILE}-YYYY-MM-DD/

set -euo pipefail

USER_PROFILE="${USER_PROFILE:-xin}"

# Validate USER_PROFILE contains only safe characters
if [[ ! "$USER_PROFILE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: USER_PROFILE must contain only alphanumeric characters, hyphens, and underscores" >&2
    exit 1
fi

BASE_DIR="${HOME}/openclaw/${USER_PROFILE}"
BACKUP_BASE="${1:-$HOME/backups}"
TIMESTAMP=$(date +%Y-%m-%d)
BACKUP_DIR="$BACKUP_BASE/openclaw-${USER_PROFILE}-$TIMESTAMP"

echo "=== OpenClaw Backup (${USER_PROFILE}) ==="
echo "Destination: $BACKUP_DIR"
echo ""

mkdir -p "$BACKUP_DIR"

# Backup user profile data
if [ -d "$BASE_DIR" ]; then
    echo "Backing up ${BASE_DIR}..."
    cp -r "$BASE_DIR" "$BACKUP_DIR/user-data"
    echo "  ✓ User data backed up"
else
    echo "  ! ${BASE_DIR} not found, skipping"
fi

# Backup OpenClaw VM config (optional)
if [ -d ~/.openclaw ]; then
    echo "Backing up ~/.openclaw (VM config)..."
    cp -r ~/.openclaw "$BACKUP_DIR/openclaw-config"
    echo "  ✓ VM config backed up"
else
    echo "  ! ~/.openclaw not found, skipping"
fi

# Backup Google Drive data (optional)
GDRIVE_BASE="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/${USER_PROFILE}"
if [ -d "$GDRIVE_BASE" ]; then
    GDRIVE_SIZE=$(du -sh "$GDRIVE_BASE" 2>/dev/null | cut -f1)
    echo "Google Drive data found ($GDRIVE_SIZE)"
    read -p "Include Google Drive data in backup? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Backing up Google Drive data..."
        cp -r "$GDRIVE_BASE" "$BACKUP_DIR/gdrive-data"
        echo "  ✓ Google Drive data backed up"
    fi
fi

# Create compressed archive
echo ""
echo "Compressing backup..."
ARCHIVE_FILE="$BACKUP_BASE/openclaw-${USER_PROFILE}-$TIMESTAMP.tar.gz"
tar -czf "$ARCHIVE_FILE" -C "$BACKUP_BASE" "openclaw-${USER_PROFILE}-$TIMESTAMP"

# Cleanup uncompressed backup
rm -rf "$BACKUP_DIR"

# Show result
ARCHIVE_SIZE=$(du -h "$ARCHIVE_FILE" | cut -f1)
echo ""
echo "=== Backup Complete ==="
echo "Archive: $ARCHIVE_FILE"
echo "Size: $ARCHIVE_SIZE"
echo ""
echo "To restore:"
echo "  tar -xzf $ARCHIVE_FILE -C ~/"
echo "  cp -r ~/openclaw-${USER_PROFILE}-$TIMESTAMP/user-data ~/openclaw/${USER_PROFILE}"
echo "  cp -r ~/openclaw-${USER_PROFILE}-$TIMESTAMP/openclaw-config ~/.openclaw"
