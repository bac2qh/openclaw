#!/bin/bash
# Backup Script for Personal Knowledge Base
#
# Creates timestamped backups of OpenClaw config, memory, and transcripts.
#
# Usage: ~/openclaw/scripts/knowledge-base/xin/backup.sh [destination]
#
# Environment variables:
#
# Default destination: ~/backups/openclaw-xin-YYYY-MM-DD/

set -euo pipefail


BASE_DIR="${HOME}/openclaw/xin"
BACKUP_BASE="${1:-$HOME/backups}"
TIMESTAMP=$(date +%Y-%m-%d)
BACKUP_DIR="$BACKUP_BASE/openclaw-xin-$TIMESTAMP"

echo "=== OpenClaw Backup (xin) ==="
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
GDRIVE_BASE="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/xin"
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
ARCHIVE_FILE="$BACKUP_BASE/openclaw-xin-$TIMESTAMP.tar.gz"
tar -czf "$ARCHIVE_FILE" -C "$BACKUP_BASE" "openclaw-xin-$TIMESTAMP"

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
echo "  cp -r ~/openclaw-xin-$TIMESTAMP/user-data ~/openclaw/xin"
echo "  cp -r ~/openclaw-xin-$TIMESTAMP/openclaw-config ~/.openclaw"
