#!/bin/bash
# Transcribe audio files with mlx-audio or stage to NAS for GPU box
#
# This script monitors ~/openclaw/xin/media/inbound/ for new audio files and routes
# them based on format: OGG files are transcribed locally, M4A files are staged to NAS.
#
# OGG (Telegram voice messages): Local whisper-turbo on Mac
# M4A (Telegram audio files): Stage to NAS (GPU box worker handles transcription on schedule)
#
# Data flow:
#   - OGG: Mac converts to MP3 → transcribes locally → saves JSON → moves OGG to NAS recordings
#   - M4A: Mac moves to NAS staging → GPU box worker transcribes → writes JSON to NAS output
#   - sync.sh pulls completed JSONs from NAS → ~/openclaw/xin/transcripts/ → Google Drive
#
# Transcripts are saved to ~/openclaw/xin/transcripts/ (shared with VM), then synced to Google Drive.
# After successful OGG transcription, audio files are moved to NAS for archival.
#
# Supported input formats: ogg, m4a (Telegram voice/audio messages)
# OGG files are converted to MP3 before transcription (miniaudio compatibility).
# M4A files are moved to NAS staging for GPU box worker to process.
#
# Usage:
#   1. Drop audio files into ~/openclaw/xin/media/inbound/
#   2. Run as daemon in tmux: tmux new-session -d -s transcribe-xin '~/openclaw/scripts/knowledge-base/xin/transcribe.sh'
#   3. Polls for new files every 2 seconds when idle
#
# Requirements:
#   - mlx-audio (pip install mlx-audio)
#   - ffmpeg (brew install ffmpeg, includes ffprobe)
#   - NAS mounted at /Volumes/NAS_1 (required for M4A staging)

# -e omitted intentionally: set -e + process substitution log pipes is a footgun for daemons
set -uo pipefail

BASE_DIR="${HOME}/openclaw/xin"
LOG_DIR="${BASE_DIR}/logs"
USER_SLUG="xin"

# Create logs directory
mkdir -p "$LOG_DIR"

# Redirect stdout/stderr through timestamp formatter to log files and terminal
exec 3>&1 4>&2
exec 1> >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"; done | tee -a "$LOG_DIR/transcribe.log" >&3)
exec 2> >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"; done | tee -a "$LOG_DIR/transcribe.err" >&4)

# Logging helpers (exec redirect above adds timestamps; log() just echoes)
log() {
    echo "$*"
}

log_err() {
    echo "ERROR: $*" >&2
}

# Instance lock: prevent running duplicate daemons
LOCKFILE="$LOG_DIR/transcribe.pid"
if [[ -f "$LOCKFILE" ]] && kill -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
    log_err "Daemon already running (PID $(cat "$LOCKFILE")). Exiting."
    exit 1
fi
echo $$ > "$LOCKFILE"

# Signal handling: log on signal, clean up lockfile on any exit
trap 'log "Shutting down..."; exit 0' SIGTERM SIGINT
trap 'rm -f "$LOCKFILE"' EXIT

# Configuration
PYTHON="${HOME}/openclaw/scripts/.venv/bin/python"   # shared
INPUT_DIR="${BASE_DIR}/media/inbound"
OUTPUT_DIR="${BASE_DIR}/transcripts"
NAS_RECORDINGS="/Volumes/NAS_1/xin/openclaw/media/recordings"
FAST_MODEL="mlx-community/whisper-large-v3-turbo-asr-fp16"
MAX_TOKENS=65536

# NAS paths
NAS_MAC_BASE="${NAS_MAC_BASE:-/Volumes/NAS_1}"
NAS_STAGING="${NAS_MAC_BASE}/${USER_SLUG}/openclaw/media/staging"

POLL_INTERVAL=2  # seconds between checks when idle

# Ensure directories exist
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

# Helper function: Get audio duration in seconds using ffprobe
get_audio_duration() {
    local file="$1"
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null | cut -d. -f1
}

# Check dependencies
if ! "$PYTHON" -c "import mlx_audio" 2>/dev/null; then
    log_err "mlx-audio not found. Install with: pip install mlx-audio"
    exit 1
fi

if ! command -v ffmpeg &> /dev/null; then
    log_err "ffmpeg not found. Install with: brew install ffmpeg"
    exit 1
fi

if ! command -v ffprobe &> /dev/null; then
    log_err "ffprobe not found. Install with: brew install ffmpeg"
    exit 1
fi

log "Transcribe daemon started (PID $$, polling every ${POLL_INTERVAL}s)"

# Process audio files in an infinite poll loop
while true; do
    # Rotate logs if they exceed 50MB to prevent unbounded growth
    for _logfile in "$LOG_DIR/transcribe.log" "$LOG_DIR/transcribe.err"; do
        if [[ -f "$_logfile" ]] && [[ $(stat -f%z "$_logfile" 2>/dev/null || echo 0) -gt $((50 * 1024 * 1024)) ]]; then
            mv "$_logfile" "${_logfile}.old"
        fi
    done

    shopt -s nullglob
    audio_files=("$INPUT_DIR"/*.ogg "$INPUT_DIR"/*.m4a)
    shopt -u nullglob

    if [[ ${#audio_files[@]} -eq 0 ]]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    log "Found ${#audio_files[@]} file(s) to process"

    for audio_file in "${audio_files[@]}"; do
        # Guard against race condition (file moved/deleted between glob and processing)
        [[ -f "$audio_file" ]] || continue

        filename=$(basename "$audio_file")
        basename_no_ext="${filename%.*}"
        extension="${filename##*.}"
        timestamp=$(date +%Y-%m-%d-%H%M%S)
        output_base="$OUTPUT_DIR/${timestamp}-${basename_no_ext}"

        log "Processing: $filename"

        # Get audio duration for informational logging
        duration=$(get_audio_duration "$audio_file")
        if [[ -n "$duration" && "$duration" =~ ^[0-9]+$ && "$duration" -gt 0 ]]; then
            duration_min=$((duration / 60))
            log "  Duration: ${duration_min} minutes (${duration}s)"
        fi

        case "$extension" in
            ogg)
                # OGG: Convert to MP3, transcribe locally with fast model
                log "  Format: OGG → local transcription (whisper-turbo)"

                log "  Converting to MP3..."
                mp3_file="$INPUT_DIR/${basename_no_ext}.mp3"
                if ffmpeg -y -i "$audio_file" -q:a 2 "$mp3_file" -loglevel warning; then
                    log "  Converted: ${basename_no_ext}.mp3"
                else
                    log_err "  Conversion failed"
                    continue
                fi

                log "  Transcribing with ${FAST_MODEL##*/}..."
                if "$PYTHON" -m mlx_audio.stt.generate \
                    --model "$FAST_MODEL" \
                    --audio "$mp3_file" \
                    --output-path "${output_base}" \
                    --format json \
                    --max-tokens "$MAX_TOKENS"; then
                    log "  Transcription saved: ${output_base}.json"

                    # Move original OGG to NAS recordings after successful transcription
                    if [[ -d "$NAS_RECORDINGS" ]]; then
                        if mv "$audio_file" "$NAS_RECORDINGS/"; then
                            log "  Moved to NAS recordings: $filename"
                        else
                            log_err "  Failed to move $filename to NAS recordings, keeping locally"
                        fi
                    else
                        log "  NAS not mounted, keeping OGG locally"
                    fi

                    # Remove converted MP3 (only needed for transcription)
                    rm -f "$mp3_file"
                    log "  Removed converted MP3: ${basename_no_ext}.mp3"
                else
                    log_err "  Transcription failed"
                    rm -f "$mp3_file"
                    continue
                fi
                ;;

            m4a)
                # M4A: Move to NAS staging for GPU box worker
                log "  Format: M4A → NAS staging"

                if [[ ! -d "$NAS_MAC_BASE" ]]; then
                    log "  NAS not mounted at $NAS_MAC_BASE, skipping $filename"
                    continue
                fi

                if ! mkdir -p "$NAS_STAGING"; then
                    log_err "  Failed to create NAS staging directory"
                    continue
                fi

                if mv "$audio_file" "$NAS_STAGING/"; then
                    log "  Moved to NAS staging: $filename"
                else
                    log_err "  Failed to move $filename to NAS staging"
                    continue
                fi
                ;;

            *)
                # Defensive: should never be reached given the glob filter above
                log_err "  Unknown format: $extension, skipping"
                continue
                ;;
        esac

        log "  Done: $filename"
    done

    log "Transcription batch complete."

    sleep 1  # Brief pause before re-checking for new files
done
