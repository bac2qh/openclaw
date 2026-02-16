#!/bin/bash
# Watches for transcripts, sends to Telegram via openclaw
# Short voice memos (<10 min) share the interactive Telegram session for
# full conversational context. Long recordings use a separate agent to
# avoid blocking, then relay key context to the main session.
#
# Watches the shared transcripts folder where host mlx-audio writes transcripts
#
# Environment variables:
#   TELEGRAM_CHAT_ID - Telegram chat ID (required)
#   AGENT_ID - Agent ID for long transcripts (default: transcript-processor)
#   DURATION_THRESHOLD - Duration threshold in seconds (default: 600)
#   OPENCLAW_STATE_DIR - OpenClaw state directory (optional, for multi-instance support)

set -uo pipefail


TRANSCRIPTS_DIR="/Volumes/My Shared Files/zhuoyue/transcripts"
PROCESSED_DIR="/Volumes/My Shared Files/zhuoyue/transcripts/processed"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-YOUR_CHAT_ID}"
AGENT_ID="${AGENT_ID:-transcript-processor}"
DURATION_THRESHOLD="${DURATION_THRESHOLD:-600}"  # 10 minutes in seconds

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

    # Detect multi-part transcript from filename pattern: {timestamp}-{name}_partN.json
    PART_META=""
    if [[ "$basename" =~ _part([0-9]+)\.json$ ]]; then
      PART_NUM="${BASH_REMATCH[1]}"
      BASE_NAME="${basename%_part*.json}"
      PART_COUNT=0
      for f in "$TRANSCRIPTS_DIR"/${BASE_NAME}_part*.json "$PROCESSED_DIR"/${BASE_NAME}_part*.json; do
        [[ -f "$f" ]] && ((PART_COUNT++))
      done
      PART_META="
**Multi-part recording:** This is part ${PART_NUM} of ${PART_COUNT} (so far) from recording '${BASE_NAME}'. Adjacent parts overlap by ~5 minutes — avoid storing duplicate content from overlap regions. If this is part 2+, treat it as a continuation of the same recording."
    fi

    # Extract duration from transcript JSON (last segment's end_time)
    DURATION_SECS=$(echo "$CONTENT" | node -e "
      let buf = '';
      process.stdin.setEncoding('utf8');
      process.stdin.on('data', c => buf += c);
      process.stdin.on('end', () => {
        try {
          const d = JSON.parse(buf);
          const s = d.segments || [];
          console.log(s.length ? Math.floor(s[s.length - 1].end_time || 0) : 0);
        } catch { console.log('0'); }
      });
    ")

    if [[ "$DURATION_SECS" -lt "$DURATION_THRESHOLD" ]]; then
      # Short transcript: route to main session for shared context
      log "  Duration: ${DURATION_SECS}s (< ${DURATION_THRESHOLD}s) → main session"
      openclaw agent \
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
      primary_result=$?
    else
      # Long transcript: route to separate agent to avoid blocking
      log "  Duration: ${DURATION_SECS}s (≥ ${DURATION_THRESHOLD}s) → separate agent"
      openclaw agent \
        --agent "$AGENT_ID" \
        --to "$TELEGRAM_CHAT_ID" \
        --channel telegram \
        --deliver \
        --message "Process this voice transcript JSON. Determine from the content and metadata whether this is a quick voice memo, a note, or a multi-person meeting, then process accordingly:
- **Voice memo/note**: Store the key facts in memory. Keep it brief.
- **Meeting**: Summarize key discussion points (3-5 bullets), extract action items with owners, identify decisions made, and update memory.
${PART_META}
Transcript JSON:
$CONTENT" \
        --thinking medium \
        --timeout 3000
      primary_result=$?

      # Relay brief context to main session so it knows what was discussed
      if [[ $primary_result -eq 0 ]]; then
        SUMMARY=$(echo "$CONTENT" | node -e "
          let buf = '';
          process.stdin.setEncoding('utf8');
          process.stdin.on('data', c => buf += c);
          process.stdin.on('end', () => {
            try {
              const d = JSON.parse(buf);
              const s = d.segments || [];
              const fullText = s.map(seg => seg.text || '').join(' ');
              const duration = s.length ? Math.floor(s[s.length - 1].end_time || 0) : 0;
              const speakers = [...new Set(s.map(seg => seg.speaker_id).filter(Boolean))];
              const mins = Math.round(duration / 60);
              const preview = fullText.substring(0, 300);
              console.log(JSON.stringify({
                duration: mins + ' min',
                speakers: speakers.length || 1,
                preview
              }));
            } catch { console.log(JSON.stringify({ duration: 'unknown', speakers: 0, preview: '' })); }
          });
        ")
        openclaw agent \
          --to "$TELEGRAM_CHAT_ID" \
          --channel telegram \
          --message "[Voice transcript context relay — a long recording was processed in a background session. Store these facts in memory for conversational context. Metadata: $SUMMARY]" \
          --thinking low \
          --timeout 120
      fi
    fi

    if [[ $primary_result -eq 0 ]]; then
      mv "$file" "$PROCESSED_DIR/"
      log "  ✓ Processed and archived: $basename"
    else
      log_err "  Failed to process transcript"
    fi
  done
  sleep 10
done
