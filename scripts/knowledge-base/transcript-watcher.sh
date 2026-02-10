#!/bin/bash
# Watches for transcripts, sends to Telegram via openclaw
# Part of the 2-watcher async transcription pipeline
#
# Watches the shared transcripts folder where host mlx-audio writes transcripts

TRANSCRIPTS_DIR="/Volumes/My Shared Files/transcripts"
PROCESSED_DIR="/Volumes/My Shared Files/transcripts/processed"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-YOUR_CHAT_ID}"
AGENT_ID="${AGENT_ID:-transcript-processor}"

mkdir -p "$PROCESSED_DIR"

# Logging helpers
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log "Starting transcript watcher..."
log "Watching: $TRANSCRIPTS_DIR"
log "Telegram chat ID: $TELEGRAM_CHAT_ID"
echo ""

if [[ "$TELEGRAM_CHAT_ID" == "YOUR_CHAT_ID" ]]; then
  log_err "Please set TELEGRAM_CHAT_ID environment variable"
  log_err "Get your chat ID by sending a message to @userinfobot on Telegram"
  exit 1
fi

log "Polling every 10 seconds for new transcripts..."
log "(VirtioFS shared folders don't support filesystem events)"
echo ""

while true; do
  for file in "$TRANSCRIPTS_DIR"/*.json; do
    [[ -f "$file" ]] || continue
    # Skip files in processed directory
    [[ "$file" =~ /processed/ ]] && continue
    basename=$(basename "$file")
    [[ -f "$PROCESSED_DIR/$basename" ]] && continue

    log "New transcript: $basename"

    CONTENT=$(cat "$file")

    openclaw agent \
      --agent "$AGENT_ID" \
      --to "$TELEGRAM_CHAT_ID" \
      --channel telegram \
      --deliver \
      --message "Process this voice transcript JSON. Determine from the content and metadata whether this is a quick voice memo, a note, or a multi-person meeting, then process accordingly:
- **Voice memo/note**: Store the key facts in memory. Keep it brief.
- **Meeting**: Summarize key discussion points (3-5 bullets), extract action items with owners, identify decisions made, and update memory.

Transcript JSON:
$CONTENT" \
      --thinking medium \
      --timeout 3000

    if [[ $? -eq 0 ]]; then
      mv "$file" "$PROCESSED_DIR/"
      log "  ✓ Processed and archived: $basename"
    else
      log_err "  Failed to process transcript"
    fi
  done
  sleep 10
done
