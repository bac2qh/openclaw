#!/bin/bash
# Transcribe audio files with mlx-audio (VibeVoice-ASR) or remote GPU
#
# This script monitors ~/openclaw/xin/media/inbound/ for new audio files and transcribes them
# using either local mlx-audio (short recordings <=10 min) or remote Ubuntu GPU box (long recordings >10 min).
#
# Short recordings (<=10 min): Local whisper-turbo on Mac
# Long recordings (>10 min): Stage to NAS + send WOL (fire and forget, GPU box worker handles transcription)
#
# Data flow:
#   - Short: Mac transcribes locally → saves to ~/openclaw/xin/transcripts/
#   - Long: Mac stages to NAS → sends WOL → GPU box worker transcribes → writes JSON to NAS output/
#   - sync.sh pulls completed JSONs from NAS → ~/openclaw/xin/transcripts/ → Google Drive
#
# Transcripts are saved to ~/openclaw/xin/transcripts/ (shared with VM), then synced to Google Drive.
# After successful transcription, audio files are moved to NAS for archival.
#
# Supported input formats: ogg, m4a (Telegram voice/audio messages)
# Short files (<=10 min) are converted to MP3 before transcription (miniaudio compatibility).
# Long files (>10 min) are staged to NAS for GPU box worker to process.
#
# Usage:
#   1. Drop audio files into ~/openclaw/xin/media/inbound/
#   2. Run as daemon in tmux: tmux new-session -d -s transcribe-xin '~/openclaw/scripts/knowledge-base/xin/transcribe.sh'
#   3. Polls for new files every 10 seconds when idle
#
# Environment variables:
#   REMOTE_ENABLED - Enable remote GPU transcription (default: true)
#   REMOTE_MAC_ADDR - Ubuntu MAC address for WOL
#
# Requirements:
#   - mlx-audio (pip install mlx-audio)
#   - ffmpeg (brew install ffmpeg)
#   - wakeonlan or etherwake (brew install wakeonlan)
#   - NAS mounted at /Volumes/NAS_1 (required for remote GPU transcription)

set -euo pipefail

trap 'log "Shutting down..."; exit 0' SIGTERM SIGINT

BASE_DIR="${HOME}/openclaw/xin"
LOG_DIR="${BASE_DIR}/logs"
USER_SLUG="xin"

# Create logs directory
mkdir -p "$LOG_DIR"

# Redirect stdout to log file with timestamps (tee to terminal and log)
exec 3>&1 4>&2
exec 1> >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"; done | tee -a "$LOG_DIR/transcribe.log" >&3)

# Redirect stderr to error log with timestamps (tee to terminal and log)
exec 2> >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"; done | tee -a "$LOG_DIR/transcribe.err" >&4)

# Configuration
PYTHON="${HOME}/openclaw/scripts/.venv/bin/python"   # shared
INPUT_DIR="${BASE_DIR}/media/inbound"
OUTPUT_DIR="${BASE_DIR}/transcripts"
GDRIVE_TRANSCRIPTS="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/xin/transcripts"
GDRIVE_WORKSPACE="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/xin/workspace"
NAS_RECORDINGS="/Volumes/NAS_1/xin/openclaw/media/recordings"
FAST_MODEL="mlx-community/whisper-large-v3-turbo-asr-fp16"
FULL_MODEL="mlx-community/VibeVoice-ASR-bf16"
MODEL_THRESHOLD=600  # Use FULL_MODEL if audio > 10 minutes (in seconds)
MAX_TOKENS=65536

# Hotwords configuration (for VibeVoice-ASR context biasing)
HOTWORDS_FILE="${BASE_DIR}/config/hotwords.txt"

# Remote GPU transcription (for long audio >10 min)
REMOTE_ENABLED="${REMOTE_ENABLED:-true}"
REMOTE_MAC_ADDR="${REMOTE_MAC_ADDR:-00:00:00:00:00:00}"  # Ubuntu MAC for WOL (set in environment)

# NAS paths
NAS_MAC_BASE="${NAS_MAC_BASE:-/Volumes/NAS_1}"
NAS_STAGING="${NAS_MAC_BASE}/${USER_SLUG}/openclaw/media/staging"

POLL_INTERVAL=2  # seconds between checks when idle

# Ensure directories exist
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

# Logging helpers
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
    echo "ERROR: $*" >&2
}

# Helper function: Read hotwords from config file (comma-separated, one term per line)
# Filters out comments (lines starting with #) and blank lines
get_hotwords_context() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local context
        context=$(grep -v '^\s*#' "$file" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//' | sed 's/,,*/,/g' | xargs)
        if [[ -n "$context" ]]; then
            echo "$context"
        fi
    fi
}

# Helper function: Get audio duration in seconds using ffprobe
get_audio_duration() {
    local file="$1"
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null | cut -d. -f1
}

# Helper function: Send Wake-on-LAN magic packet
send_wol() {
    local mac_addr="$1"

    if command -v wakeonlan &> /dev/null; then
        wakeonlan "$mac_addr" &> /dev/null
        return $?
    elif command -v etherwake &> /dev/null; then
        etherwake "$mac_addr" &> /dev/null
        return $?
    else
        log_err "No WOL tool found (wakeonlan or etherwake)"
        return 1
    fi
}

# Helper function: Stage audio file to NAS
stage_audio_to_nas() {
    local audio_file="$1"
    local filename=$(basename "$audio_file")

    if [[ ! -d "$NAS_STAGING" ]]; then
        mkdir -p "$NAS_STAGING" || {
            log_err "Failed to create NAS staging directory"
            return 1
        }
    fi

    local staged_path="${NAS_STAGING}/${filename}"
    if cp "$audio_file" "$staged_path"; then
        echo "$staged_path"
        return 0
    else
        log_err "Failed to stage audio to NAS"
        return 1
    fi
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

# Check remote GPU dependencies
if [[ "$REMOTE_ENABLED" == "true" ]]; then
    if ! command -v wakeonlan &> /dev/null && ! command -v etherwake &> /dev/null; then
        log_err "Remote GPU enabled but no WOL tool found. Install with: brew install wakeonlan"
        exit 1
    fi

    if [[ ! -d "$NAS_MAC_BASE" ]]; then
        log_err "Remote GPU enabled but NAS not mounted at $NAS_MAC_BASE"
        exit 1
    fi
fi

log "Transcribe daemon started (polling every ${POLL_INTERVAL}s)"

# Process audio files in an infinite poll loop
while true; do
    shopt -s nullglob
    audio_files=("$INPUT_DIR"/*.ogg "$INPUT_DIR"/*.m4a)

    if [[ ${#audio_files[@]} -eq 0 ]]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    log "Found ${#audio_files[@]} file(s) to process"

    for audio_file in "${audio_files[@]}"; do
        # Skip if no files match
        [ -e "$audio_file" ] || continue

        filename=$(basename "$audio_file")
        basename_no_ext="${filename%.*}"
        extension="${filename##*.}"
        timestamp=$(date +%Y-%m-%d-%H%M)
        output_base="$OUTPUT_DIR/${timestamp}-${basename_no_ext}"

        log "Processing: $filename"

        # Get audio duration from original file (ffprobe handles m4a/ogg natively)
        duration=$(get_audio_duration "$audio_file")
        if [[ -z "$duration" || "$duration" -eq 0 ]]; then
            log_err "  Could not determine audio duration"
            continue
        fi

        duration_min=$((duration / 60))
        log "  Duration: ${duration_min} minutes (${duration}s)"

        # Select model based on duration
        if [[ "$duration" -gt "$MODEL_THRESHOLD" ]]; then
            selected_model="$FULL_MODEL"
            log "  Model: VibeVoice-ASR (long recording)"
        else
            selected_model="$FAST_MODEL"
            log "  Model: whisper-turbo (short recording)"
        fi

        # Load hotwords context for VibeVoice-ASR model
        context_args=()
        if [[ "$selected_model" == "$FULL_MODEL" ]]; then
            hotwords=$(get_hotwords_context "$HOTWORDS_FILE")
            if [[ -n "$hotwords" ]]; then
                context_args=(--context "$hotwords")
                log "  Context: $hotwords"
            fi
        fi

        # Branch on duration: short files need MP3 conversion, long files skip it
        if [[ "$duration" -le "$MODEL_THRESHOLD" ]]; then
            # Short audio (<= 10 min): Convert to MP3 and transcribe with whisper-turbo
            log "  Converting to MP3 for whisper-turbo..."
            mp3_file="$INPUT_DIR/${basename_no_ext}.mp3"
            if ffmpeg -y -i "$audio_file" -q:a 2 "$mp3_file" -loglevel warning; then
                log "  ✓ Converted: ${basename_no_ext}.mp3"
            else
                log_err "  Conversion failed"
                continue
            fi

            log "  Transcribing with ${selected_model##*/}..."
            if "$PYTHON" -m mlx_audio.stt.generate \
                --model "$selected_model" \
                --audio "$mp3_file" \
                --output-path "${output_base}" \
                --format json \
                --max-tokens "$MAX_TOKENS" \
                ${context_args[@]+"${context_args[@]}"}; then
                log "  ✓ Transcription saved: ${output_base}.json"

                # Move audio files to NAS after successful transcription
                if [ -d "$NAS_RECORDINGS" ]; then
                    mv "$audio_file" "$NAS_RECORDINGS/"
                    log "  ✓ Moved to NAS: $filename"
                    # Remove the converted MP3 (only needed for transcription)
                    rm -f "$mp3_file"
                    log "  ✓ Removed converted MP3: ${basename_no_ext}.mp3"
                else
                    log "  ⚠ NAS not mounted, keeping files locally"
                fi
            else
                log_err "  Transcription failed"
                continue
            fi
        else
            # Long audio (> 10 min): Use remote GPU or local fallback
            if [[ "$REMOTE_ENABLED" == "true" ]]; then
                # Remote GPU transcription path (fire and forget)
                log "  Staging to NAS for GPU transcription..."
                staged_path=$(stage_audio_to_nas "$audio_file")
                if [[ -z "$staged_path" ]]; then
                    log_err "  Failed to stage audio to NAS"
                    continue
                fi
                log "  ✓ Staged: $(basename "$staged_path")"

                # Copy latest hotwords to NAS (so GPU box has fresh context)
                if [[ -f "$HOTWORDS_FILE" ]]; then
                    mkdir -p "${NAS_MAC_BASE}/${USER_SLUG}/openclaw/config"
                    cp "$HOTWORDS_FILE" "${NAS_MAC_BASE}/${USER_SLUG}/openclaw/config/hotwords.txt"
                    log "  ✓ Hotwords synced to NAS"
                fi

                # Wake GPU box (fire and forget)
                send_wol "$REMOTE_MAC_ADDR"
                log "  ✓ WOL sent to GPU box"

                # Move original out of inbound (NAS staging is the source of truth now)
                rm -f "$audio_file"
                log "  ✓ Removed from inbound (staged on NAS)"

            else
                # REMOTE_ENABLED=false: Local fallback (transcribe directly)
                log "  Remote GPU disabled, using local transcription..."
                log "  Transcribing original file with ${selected_model##*/} (no conversion)..."
                if "$PYTHON" -m mlx_audio.stt.generate \
                    --model "$selected_model" \
                    --audio "$audio_file" \
                    --output-path "${output_base}" \
                    --format json \
                    --max-tokens "$MAX_TOKENS" \
                    ${context_args[@]+"${context_args[@]}"}; then
                    log "  ✓ Transcription saved: ${output_base}.json"

                    # Move audio file to NAS after successful transcription
                    if [ -d "$NAS_RECORDINGS" ]; then
                        mv "$audio_file" "$NAS_RECORDINGS/"
                        log "  ✓ Moved to NAS: $filename"
                    else
                        log "  ⚠ NAS not mounted, keeping files locally"
                    fi
                else
                    log_err "  Transcription failed"
                    continue
                fi
            fi
        fi

        log "  ✓ Done: $filename"
        echo ""
    done

    log "Transcription batch complete."

    sleep 1  # Brief pause before re-checking for new files
done
