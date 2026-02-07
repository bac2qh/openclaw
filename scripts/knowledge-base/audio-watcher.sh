#!/bin/bash
# Watches ~/.openclaw/media/ for new audio, copies to shared recordings folder
# Part of the 2-watcher async transcription pipeline

MEDIA_DIR="${HOME}/.openclaw/media"
SHARED_RECORDINGS="/Volumes/My Shared Files/recordings"

mkdir -p "$SHARED_RECORDINGS"

echo "Starting audio watcher..."
echo "Watching: $MEDIA_DIR"
echo "Copying to: $SHARED_RECORDINGS"
echo ""

fswatch -0 "$MEDIA_DIR" | while read -d "" file; do
  if [[ "$file" =~ \.(ogg|mp3|m4a|wav|flac|webm|mp4)$ ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] New audio: $(basename "$file")"
    cp "$file" "$SHARED_RECORDINGS/"
    echo "  → Copied to $SHARED_RECORDINGS/"
  fi
done
