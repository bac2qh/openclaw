#!/bin/bash
# Backup Script for Personal Knowledge Base
#
# Creates timestamped backups of OpenClaw config, memory, and transcripts.
#
# Usage: ./backup.sh [destination]
#
# Default destination: ~/backups/openclaw-YYYY-MM-DD/

set -euo pipefail

BACKUP_BASE="${1:-$HOME/backups}"
TIMESTAMP=$(date +%Y-%m-%d)
BACKUP_DIR="$BACKUP_BASE/openclaw-$TIMESTAMP"

echo "=== OpenClaw Backup ==="
echo "Destination: $BACKUP_DIR"
echo ""

mkdir -p "$BACKUP_DIR"

# Backup OpenClaw config
if [ -d ~/.openclaw ]; then
    echo "Backing up ~/.openclaw..."
    cp -r ~/.openclaw "$BACKUP_DIR/openclaw-config"
    echo "  ✓ Config backed up"
else
    echo "  ! ~/.openclaw not found, skipping"
fi

# Backup transcripts
if [ -d ~/transcripts ]; then
    echo "Backing up ~/transcripts..."
    cp -r ~/transcripts "$BACKUP_DIR/transcripts"
    echo "  ✓ Transcripts backed up"
else
    echo "  ! ~/transcripts not found, skipping"
fi

# Backup audio archive (optional)
if [ -d ~/audio-archive ]; then
    ARCHIVE_SIZE=$(du -sh ~/audio-archive 2>/dev/null | cut -f1)
    echo "Audio archive found ($ARCHIVE_SIZE)"
    read -p "Include audio archive in backup? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Backing up ~/audio-archive..."
        cp -r ~/audio-archive "$BACKUP_DIR/audio-archive"
        echo "  ✓ Audio archive backed up"
    fi
fi

# Create compressed archive
echo ""
echo "Compressing backup..."
ARCHIVE_FILE="$BACKUP_BASE/openclaw-$TIMESTAMP.tar.gz"
tar -czf "$ARCHIVE_FILE" -C "$BACKUP_BASE" "openclaw-$TIMESTAMP"

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
echo "  cp -r ~/openclaw-$TIMESTAMP/openclaw-config ~/.openclaw"
echo "  cp -r ~/openclaw-$TIMESTAMP/transcripts ~/transcripts"
