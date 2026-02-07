#!/bin/bash
# Watches for transcripts, sends to Telegram via openclaw
# Part of the 2-watcher async transcription pipeline
#
# Watches the shared transcripts folder where host mlx-audio writes transcripts

TRANSCRIPTS_DIR="/Volumes/My Shared Files/transcripts"
PROCESSED_DIR="/Volumes/My Shared Files/transcripts/processed"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-YOUR_CHAT_ID}"

mkdir -p "$PROCESSED_DIR"

echo "Starting transcript watcher..."
echo "Watching: $TRANSCRIPTS_DIR"
echo "Telegram chat ID: $TELEGRAM_CHAT_ID"
echo ""

if [[ "$TELEGRAM_CHAT_ID" == "YOUR_CHAT_ID" ]]; then
  echo "ERROR: Please set TELEGRAM_CHAT_ID environment variable"
  echo "Get your chat ID by sending a message to @userinfobot on Telegram"
  exit 1
fi

fswatch -0 "$TRANSCRIPTS_DIR" | while read -d "" file; do
  # Only process .json files
  [[ "$file" =~ \.json$ ]] || continue
  [[ -f "$file" ]] || continue

  # Skip files in processed directory
  [[ "$file" =~ /processed/ ]] && continue

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] New transcript: $(basename "$file")"

  # Extract text from JSON array format
  TEXT=$(jq -r '.[].Content' "$file" 2>/dev/null | tr '\n' ' ')

  if [[ -n "$TEXT" ]]; then
    # Extract metadata from transcript JSON
    SEGMENT_COUNT=$(jq 'length' "$file" 2>/dev/null || echo 0)
    WORD_COUNT=$(echo "$TEXT" | wc -w | xargs)
    SPEAKER_COUNT=$(jq '[.[].speaker_id // .[].Speaker // "unknown"] | unique | length' "$file" 2>/dev/null || echo 1)
    DURATION=$(jq '((last.end_time // last.End // 0) - (first.start_time // first.Start // 0))' "$file" 2>/dev/null || echo 0)
    DURATION_MIN=$(echo "scale=1; $DURATION / 60" | bc 2>/dev/null || echo "0")

    # Trigger AI to process transcript with adaptive prompt
    # With experimental.sessionMemory enabled, this conversation is auto-indexed
    openclaw agent \
      --message "Process this voice transcript. Here is context about the recording:
- Duration: ~${DURATION_MIN} minutes
- Speakers: ${SPEAKER_COUNT}
- Words: ${WORD_COUNT}
- Segments: ${SEGMENT_COUNT}

Based on the content and metadata, determine if this is a quick voice memo, a note, or a multi-person meeting, then process accordingly:
- **Voice memo/note**: Store the key facts in memory. Keep it brief.
- **Meeting**: Summarize key discussion points (3-5 bullets), extract action items with owners, identify decisions made, and update memory.

Transcript:
$TEXT" \
      --thinking medium \
      --timeout 300

    if [[ $? -eq 0 ]]; then
      # Move to processed directory only if processing succeeded
      mv "$file" "$PROCESSED_DIR/"
      echo "  → Processed and archived: $(basename "$file")"
    else
      echo "  → Error: Failed to process transcript"
    fi
  else
    echo "  → Warning: Could not parse transcript"
  fi
done
