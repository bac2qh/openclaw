#!/bin/bash
# Watches for new audio files in the shared recordings folder
# Part of the 2-watcher async transcription pipeline
#
# Note: With the unified ~/openclaw folder approach, OpenClaw downloads
# audio directly to the shared folder (no copy needed).
# This watcher is optional - just for monitoring/logging.

RECORDINGS_DIR="/Volumes/My Shared Files/media/recordings"

echo "Starting audio monitor..."
echo "Watching: $RECORDINGS_DIR"
echo ""

fswatch -0 "$RECORDINGS_DIR" | while read -d "" file; do
  if [[ "$file" =~ \.(ogg|mp3|m4a|wav|flac|webm|mp4)$ ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] New audio detected: $(basename "$file")"
    echo "  → Ready for host transcription"
  fi
done
