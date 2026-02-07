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
  # Only process .txt files
  [[ "$file" =~ \.txt$ ]] || continue
  [[ -f "$file" ]] || continue

  # Skip files in processed directory
  [[ "$file" =~ /processed/ ]] && continue

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] New transcript: $(basename "$file")"

  # Extract text from JSON array format
  TEXT=$(jq -r '.[].Content' "$file" 2>/dev/null | tr '\n' ' ')

  if [[ -n "$TEXT" ]]; then
    # Trigger AI to process transcript
    # With experimental.sessionMemory enabled, this conversation is auto-indexed
    openclaw agent \
      --message "Process this meeting transcript and:
1. Summarize key discussion points (3-5 bullets)
2. Extract action items with owners and due dates
3. Identify key decisions made
4. Update your memory with important facts

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
