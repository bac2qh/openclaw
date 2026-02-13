#!/bin/bash
# Transcribe audio files with mlx-audio (VibeVoice-ASR)
#
# This script monitors ~/openclaw/{USER_PROFILE}/media/inbound/ for new audio files and transcribes them
# using mlx-audio with Microsoft's VibeVoice-ASR model (includes speaker diarization).
# Transcripts are saved to ~/openclaw/{USER_PROFILE}/transcripts/ (shared with VM), then synced to Google Drive.
# After successful transcription, audio files are moved to NAS for archival.
#
# Supported input formats: ogg, m4a (Telegram voice/audio messages)
# Files are converted to MP3 before transcription (miniaudio compatibility).
#
# Usage:
#   1. Drop audio files into ~/openclaw/{USER_PROFILE}/media/inbound/
#   2. Run manually: USER_PROFILE=xin ~/openclaw/scripts/transcribe.sh
#   3. Or auto-run via launchd (see setup guide)
#
# Environment variables:
#   USER_PROFILE - User profile name (default: xin)
#
# Requirements:
#   - mlx-audio (pip install mlx-audio)
#   - ffmpeg (brew install ffmpeg)
#   - rsync (built-in on macOS)
#   - Insync (Google Drive) mounted at ~/Insync/bac2qh@gmail.com/Google Drive (optional, for cloud sync)
#   - NAS mounted at /Volumes/NAS_1 (optional, files kept locally if not mounted)

set -euo pipefail

# Timestamp all stderr output (for launchd error log)
exec 2> >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"; done >&2)

# User profile
USER_PROFILE="${USER_PROFILE:-xin}"

# Validate USER_PROFILE contains only safe characters
if [[ ! "$USER_PROFILE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: USER_PROFILE must contain only alphanumeric characters, hyphens, and underscores" >&2
    exit 1
fi

BASE_DIR="${HOME}/openclaw/${USER_PROFILE}"

# Configuration
PYTHON="${HOME}/openclaw/scripts/.venv/bin/python"   # shared
INPUT_DIR="${BASE_DIR}/media/inbound"
OUTPUT_DIR="${BASE_DIR}/transcripts"
GDRIVE_TRANSCRIPTS="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/${USER_PROFILE}/transcripts"
GDRIVE_WORKSPACE="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/${USER_PROFILE}/workspace"
NAS_RECORDINGS="/Volumes/NAS_1/${USER_PROFILE}/openclaw/media/recordings"
FAST_MODEL="mlx-community/whisper-large-v3-turbo-asr-fp16"
FULL_MODEL="mlx-community/VibeVoice-ASR-bf16"
MODEL_THRESHOLD=600  # Use FULL_MODEL if audio > 10 minutes (in seconds)
MAX_TOKENS=65536

# Chunking configuration (for long recordings)
CHUNK_THRESHOLD=3300 # Split if audio > 55 minutes (in seconds)
CHUNK_DURATION=3300  # 55 minutes per chunk (in seconds)
CHUNK_STEP=3000      # Start next chunk at 50 minutes (5 min overlap)

# Hotwords configuration (for VibeVoice-ASR context biasing)
HOTWORDS_FILE="${BASE_DIR}/config/hotwords.txt"

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

# Helper function: Split audio into overlapping chunks
split_audio_into_chunks() {
    local input_file="$1"
    local output_base="$2"  # e.g., /path/to/filename (no extension)
    local duration="$3"

    local chunk_num=1
    local start_time=0
    local chunks=()

    log "  Splitting into overlapping chunks (55 min each, 5 min overlap)..."

    while [[ $start_time -lt $duration ]]; do
        local chunk_file="${output_base}_part${chunk_num}.mp3"
        log "    Creating chunk $chunk_num (start: ${start_time}s)..."

        if ffmpeg -y -i "$input_file" -ss "$start_time" -t "$CHUNK_DURATION" \
            -c:a libmp3lame -q:a 2 "$chunk_file" -loglevel warning; then
            chunks+=("$chunk_file")
            log "    ✓ Chunk $chunk_num created"
        else
            log_err "    Failed to create chunk $chunk_num"
            return 1
        fi

        ((chunk_num++))
        ((start_time += CHUNK_STEP))
    done

    echo "${chunks[@]}"
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

# Process each audio file (any format ffmpeg supports)
shopt -s nullglob
for audio_file in "$INPUT_DIR"/*.ogg "$INPUT_DIR"/*.m4a; do
    # Skip if no files match
    [ -e "$audio_file" ] || continue

    filename=$(basename "$audio_file")
    basename_no_ext="${filename%.*}"
    extension="${filename##*.}"
    timestamp=$(date +%Y-%m-%d-%H%M)
    output_base="$OUTPUT_DIR/${timestamp}-${basename_no_ext}"

    log "Processing: $filename"

    # Convert to MP3 if not already (miniaudio only reliably supports mp3/wav/flac)
    if [[ "$extension" == "mp3" ]]; then
        mp3_file="$audio_file"
        converted=false
    else
        mp3_file="$INPUT_DIR/${basename_no_ext}.mp3"
        log "  Converting to MP3..."
        if ffmpeg -y -i "$audio_file" -q:a 2 "$mp3_file" -loglevel warning; then
            log "  ✓ Converted: ${basename_no_ext}.mp3"
            converted=true
        else
            log_err "  Conversion failed"
            continue
        fi
    fi

    # Get audio duration
    duration=$(get_audio_duration "$mp3_file")
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

    # Check if audio needs to be split into chunks
    if [[ "$duration" -gt "$CHUNK_THRESHOLD" ]]; then
        log "  Audio is longer than 55 minutes, splitting into chunks..."

        # Split audio into chunks
        chunk_base="$INPUT_DIR/${basename_no_ext}"
        chunks=$(split_audio_into_chunks "$mp3_file" "$chunk_base" "$duration")

        if [[ -z "$chunks" ]]; then
            log_err "  Failed to create chunks"
            continue
        fi

        # Transcribe each chunk
        transcription_failed=false
        chunk_files=()
        for chunk_file in $chunks; do
            chunk_basename=$(basename "$chunk_file" .mp3)
            chunk_output="${output_base}_${chunk_basename##*_}"  # Extract partN from filename

            log "  Transcribing chunk: $(basename "$chunk_file")..."
            if "$PYTHON" -m mlx_audio.stt.generate \
                --model "$selected_model" \
                --audio "$chunk_file" \
                --output-path "${chunk_output}" \
                --format json \
                --max-tokens "$MAX_TOKENS" \
                "${context_args[@]}"; then
                log "    ✓ Chunk transcription saved: ${chunk_output}.json"
                chunk_files+=("$chunk_file")
            else
                log_err "    Chunk transcription failed"
                transcription_failed=true
                break
            fi
        done

        # Clean up chunk files if all transcriptions succeeded
        if [[ "$transcription_failed" == false ]]; then
            log "  ✓ All chunks transcribed successfully"
            for chunk_file in "${chunk_files[@]}"; do
                rm -f "$chunk_file"
                log "  ✓ Cleaned up: $(basename "$chunk_file")"
            done

            # Move original audio to NAS
            if [ -d "$NAS_RECORDINGS" ]; then
                mv "$audio_file" "$NAS_RECORDINGS/"
                log "  ✓ Moved to NAS: $filename"
                # Remove the converted MP3 (only needed for transcription)
                if [[ "$converted" == true ]]; then
                    rm -f "$mp3_file"
                    log "  ✓ Removed converted MP3: ${basename_no_ext}.mp3"
                fi
            else
                log "  ⚠ NAS not mounted, keeping files locally"
            fi
        else
            log_err "  Some chunks failed to transcribe, keeping all files"
            continue
        fi
    else
        # Audio is under threshold, transcribe as single file (existing behavior)
        log "  Transcribing with ${selected_model##*/}..."
        if "$PYTHON" -m mlx_audio.stt.generate \
            --model "$selected_model" \
            --audio "$mp3_file" \
            --output-path "${output_base}" \
            --format json \
            --max-tokens "$MAX_TOKENS" \
            "${context_args[@]}"; then
            log "  ✓ Transcription saved: ${output_base}.json"

            # Move audio files to NAS after successful transcription
            if [ -d "$NAS_RECORDINGS" ]; then
                mv "$audio_file" "$NAS_RECORDINGS/"
                log "  ✓ Moved to NAS: $filename"
                # Remove the converted MP3 (only needed for transcription)
                if [[ "$converted" == true ]]; then
                    rm -f "$mp3_file"
                    log "  ✓ Removed converted MP3: ${basename_no_ext}.mp3"
                fi
            else
                log "  ⚠ NAS not mounted, keeping files locally"
            fi
        else
            log_err "  Transcription failed"
            continue
        fi
    fi

    log "  ✓ Done: $filename"
    echo ""
done

log "Transcription batch complete."

# Sync transcripts and workspace to Google Drive
if [ -d "$GDRIVE_TRANSCRIPTS" ] && [ -d "$GDRIVE_WORKSPACE" ]; then
    echo ""
    log "Syncing to Google Drive..."

    # Sync transcripts (with safety limit on deletions)
    if rsync -av --delete --max-delete=10 "$OUTPUT_DIR/" "$GDRIVE_TRANSCRIPTS/"; then
        log "  ✓ Transcripts synced to Google Drive"
    else
        log_err "  ⚠ Warning: Failed to sync transcripts to Google Drive"
    fi

    # Sync workspace (if it exists, with safety limit on deletions)
    if [ -d "${BASE_DIR}/workspace" ]; then
        if rsync -av --delete --max-delete=10 "${BASE_DIR}/workspace/" "$GDRIVE_WORKSPACE/"; then
            log "  ✓ Workspace synced to Google Drive"
        else
            log_err "  ⚠ Warning: Failed to sync workspace to Google Drive"
        fi
    fi
else
    log "  ⚠ Google Drive not available, skipping cloud sync"
fi
