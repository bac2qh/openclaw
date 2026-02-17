#!/bin/bash
# Transcribe audio files with mlx-audio (VibeVoice-ASR) or remote GPU
#
# This script monitors ~/openclaw/zhuoyue/media/inbound/ for new audio files and transcribes them
# using either local mlx-audio (short recordings <=10 min) or remote Ubuntu GPU box (long recordings >10 min).
#
# Short recordings (<=10 min): Local whisper-turbo on Mac
# Medium recordings (10-30 min): Wake Ubuntu GPU box via WOL, stage to NAS, transcribe via Docker
# Long recordings (>30 min): Split into chunks, stage to NAS, transcribe each chunk on GPU
#
# Data flow: Audio staged to NAS → Ubuntu transcribes, writes JSON to NAS → Mac copies JSON
# from NAS to ~/openclaw/zhuoyue/transcripts/ → rsync syncs transcripts to Google Drive
#
# Transcripts are saved to ~/openclaw/zhuoyue/transcripts/ (shared with VM), then synced to Google Drive.
# After successful transcription, audio files are moved to NAS for archival.
#
# Supported input formats: ogg, m4a (Telegram voice/audio messages)
# Short files (<=10 min) are converted to MP3 before transcription (miniaudio compatibility).
# Long files (>10 min) skip conversion on Mac — remote GPU handles original format or MP3 chunks.
#
# Usage:
#   1. Drop audio files into ~/openclaw/zhuoyue/media/inbound/
#   2. Run as daemon in tmux: tmux new-session -d -s transcribe-zhuoyue '~/openclaw/scripts/knowledge-base/zhuoyue/transcribe.sh'
#   3. Polls for new files every 10 seconds when idle
#
# Environment variables:
#   REMOTE_ENABLED - Enable remote GPU transcription (default: true)
#   REMOTE_MAC_ADDR - Ubuntu MAC address for WOL
#   REMOTE_HOST - SSH hostname for Ubuntu GPU box
#
# Requirements:
#   - mlx-audio (pip install mlx-audio)
#   - ffmpeg (brew install ffmpeg)
#   - rsync (built-in on macOS)
#   - wakeonlan or etherwake (brew install wakeonlan)
#   - Insync (Google Drive) mounted at ~/Insync/bac2qh@gmail.com/Google Drive (optional, for cloud sync)
#   - NAS mounted at /Volumes/NAS_1 (required for remote GPU transcription)

set -euo pipefail

trap 'log "Shutting down..."; exit 0' SIGTERM SIGINT

BASE_DIR="${HOME}/openclaw/zhuoyue"
LOG_DIR="${BASE_DIR}/logs"

# Create logs directory
mkdir -p "$LOG_DIR"

# Redirect stdout to log file with timestamps
exec 1> >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"; done >> "$LOG_DIR/transcribe.log")

# Redirect stderr to error log with timestamps
exec 2> >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"; done >> "$LOG_DIR/transcribe.err")

# Configuration
PYTHON="${HOME}/openclaw/scripts/.venv/bin/python"   # shared
INPUT_DIR="${BASE_DIR}/media/inbound"
OUTPUT_DIR="${BASE_DIR}/transcripts"
GDRIVE_TRANSCRIPTS="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/zhuoyue/transcripts"
GDRIVE_WORKSPACE="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/zhuoyue/workspace"
NAS_RECORDINGS="/Volumes/NAS_1/zhuoyue/openclaw/media/recordings"
FAST_MODEL="mlx-community/whisper-large-v3-turbo-asr-fp16"
FULL_MODEL="mlx-community/VibeVoice-ASR-bf16"
MODEL_THRESHOLD=600  # Use FULL_MODEL if audio > 10 minutes (in seconds)
MAX_TOKENS=65536

# Chunking configuration (for long recordings)
CHUNK_THRESHOLD=1800 # Split if audio > 30 minutes (in seconds)
CHUNK_DURATION=1800  # 30 minutes per chunk (in seconds)
CHUNK_STEP=1500      # Start next chunk at 25 minutes (5 min overlap)

# Hotwords configuration (for VibeVoice-ASR context biasing)
HOTWORDS_FILE="${BASE_DIR}/config/hotwords.txt"

# Remote GPU transcription (for long audio >10 min)
REMOTE_ENABLED="${REMOTE_ENABLED:-true}"
REMOTE_MAC_ADDR="${REMOTE_MAC_ADDR:-00:00:00:00:00:00}"  # Ubuntu MAC for WOL (set in environment)
REMOTE_HOST="${REMOTE_HOST:-gpu-box}"                     # SSH hostname
REMOTE_USER="${REMOTE_USER:-xin}"
REMOTE_SSH_PORT="${REMOTE_SSH_PORT:-22}"
REMOTE_SSH_TIMEOUT=10
REMOTE_BOOT_TIMEOUT=120                                   # Max wait after WOL
REMOTE_BOOT_POLL_INTERVAL=5

# NAS paths (differ per OS)
NAS_MAC_BASE="${NAS_MAC_BASE:-/Volumes/NAS_1}"
NAS_STAGING="${NAS_MAC_BASE}/zhuoyue/openclaw/media/staging"
NAS_REMOTE_BASE="${NAS_REMOTE_BASE:-/mnt/nas}"            # Ubuntu mount point

# Docker config
REMOTE_DOCKER_IMAGE="${REMOTE_DOCKER_IMAGE:-vibevoice-asr:latest}"
REMOTE_SUSPEND_AFTER="${REMOTE_SUSPEND_AFTER:-true}"

POLL_INTERVAL=10  # seconds between checks when idle

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

    log "  Splitting into overlapping chunks (30 min each, 5 min overlap)..."

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

# Helper function: Wait for SSH to become available
wait_for_ssh() {
    local host="$1"
    local port="$2"
    local timeout="$3"
    local poll_interval="$4"

    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p "$port" "${REMOTE_USER}@${host}" "exit" &> /dev/null; then
            return 0
        fi
        sleep "$poll_interval"
        ((elapsed += poll_interval))
    done

    return 1
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

# Helper function: Run remote transcription via Docker
run_remote_transcription() {
    local staged_filename="$1"  # just the filename, not full path
    local output_basename="$2"  # e.g., "2024-01-15-1430-recording"
    local hotwords="$3"         # optional context

    # Build remote paths (Ubuntu perspective)
    local remote_staging="${NAS_REMOTE_BASE}/zhuoyue/openclaw/media/staging"
    local remote_audio="${remote_staging}/${staged_filename}"
    local remote_output="${remote_staging}/output/${output_basename}"

    # Build Docker command
    local docker_cmd="docker run --rm --gpus all -v ${remote_staging}:/data ${REMOTE_DOCKER_IMAGE} --audio /data/${staged_filename} --output-path /data/output/${output_basename} --format json"

    if [[ -n "$hotwords" ]]; then
        docker_cmd="${docker_cmd} --context \"${hotwords}\""
    fi

    # Run Docker via SSH
    if ssh -o ConnectTimeout="$REMOTE_SSH_TIMEOUT" -o StrictHostKeyChecking=no -p "$REMOTE_SSH_PORT" "${REMOTE_USER}@${REMOTE_HOST}" "$docker_cmd" &> /dev/null; then
        return 0
    else
        log_err "Remote transcription failed"
        return 1
    fi
}

# Helper function: Collect transcript JSON from NAS to local transcripts dir
collect_remote_transcript() {
    local output_basename="$1"  # e.g., "2024-01-15-1430-recording"

    local nas_output="${NAS_STAGING}/output/${output_basename}.json"
    local local_output="${OUTPUT_DIR}/${output_basename}.json"

    if [[ -f "$nas_output" ]]; then
        if cp "$nas_output" "$local_output"; then
            rm -f "$nas_output"  # Clean up NAS staging output
            return 0
        else
            log_err "Failed to copy transcript from NAS"
            return 1
        fi
    else
        log_err "Remote transcript not found at $nas_output"
        return 1
    fi
}

# Helper function: Suspend remote Ubuntu box
suspend_remote() {
    if [[ "$REMOTE_SUSPEND_AFTER" == "true" ]]; then
        log "  Suspending remote GPU box..."
        ssh -o ConnectTimeout="$REMOTE_SSH_TIMEOUT" -o StrictHostKeyChecking=no -p "$REMOTE_SSH_PORT" "${REMOTE_USER}@${REMOTE_HOST}" "sudo systemctl suspend" &> /dev/null || {
            log "  ⚠ Failed to suspend remote host (may require passwordless sudo)"
        }
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

    # Check if remote host is currently reachable (non-fatal, will WOL it)
    if ! ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -p "$REMOTE_SSH_PORT" "${REMOTE_USER}@${REMOTE_HOST}" "exit" &> /dev/null; then
        log "  Note: Remote GPU box not currently reachable (will wake via WOL when needed)"
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
                # Remote GPU transcription path
                log "  Using remote GPU transcription..."

                # Wake remote GPU box
                log "  Waking remote GPU box..."
                if ! send_wol "$REMOTE_MAC_ADDR"; then
                    log_err "  Failed to send WOL packet"
                    continue
                fi

                log "  Waiting for SSH (timeout: ${REMOTE_BOOT_TIMEOUT}s)..."
                if ! wait_for_ssh "$REMOTE_HOST" "$REMOTE_SSH_PORT" "$REMOTE_BOOT_TIMEOUT" "$REMOTE_BOOT_POLL_INTERVAL"; then
                    log_err "  Remote host not reachable after WOL"
                    continue
                fi
                log "  ✓ Remote host is up"

                # Branch on duration: chunked vs. medium
                if [[ "$duration" -gt "$CHUNK_THRESHOLD" ]]; then
                    # Very long audio (> 30 min): Split into chunks and transcribe remotely
                    log "  Audio is longer than 30 minutes, splitting into chunks..."

                    # Split audio into MP3 chunks locally
                    chunk_base="$INPUT_DIR/${basename_no_ext}"
                    chunks=$(split_audio_into_chunks "$audio_file" "$chunk_base" "$duration")

                    if [[ -z "$chunks" ]]; then
                        log_err "  Failed to create chunks"
                        continue
                    fi

                    # Stage and transcribe each chunk remotely
                    transcription_failed=false
                    chunk_files=()
                    staged_chunks=()

                    for chunk_file in $chunks; do
                        chunk_filename=$(basename "$chunk_file")
                        chunk_basename=$(basename "$chunk_file" .mp3)
                        chunk_output_base="${timestamp}-${basename_no_ext}_${chunk_basename##*_}"

                        log "  Staging chunk: $chunk_filename..."
                        staged_chunk=$(stage_audio_to_nas "$chunk_file")
                        if [[ -z "$staged_chunk" ]]; then
                            log_err "  Failed to stage chunk"
                            transcription_failed=true
                            break
                        fi
                        staged_chunks+=("$staged_chunk")

                        log "  Transcribing chunk remotely: $chunk_filename..."
                        hotwords=$(get_hotwords_context "$HOTWORDS_FILE")
                        if ! run_remote_transcription "$chunk_filename" "$chunk_output_base" "$hotwords"; then
                            log_err "  Remote transcription failed for chunk"
                            transcription_failed=true
                            break
                        fi

                        log "  Collecting transcript: $chunk_output_base..."
                        if ! collect_remote_transcript "$chunk_output_base"; then
                            log_err "  Failed to collect transcript"
                            transcription_failed=true
                            break
                        fi

                        log "    ✓ Chunk transcription complete: ${chunk_output_base}.json"
                        chunk_files+=("$chunk_file")
                    done

                    # Clean up
                    if [[ "$transcription_failed" == false ]]; then
                        log "  ✓ All chunks transcribed successfully"

                        # Remove local chunks
                        for chunk_file in "${chunk_files[@]}"; do
                            rm -f "$chunk_file"
                            log "  ✓ Removed local chunk: $(basename "$chunk_file")"
                        done

                        # Remove staged chunks from NAS
                        for staged_chunk in "${staged_chunks[@]}"; do
                            rm -f "$staged_chunk"
                            log "  ✓ Removed staged chunk: $(basename "$staged_chunk")"
                        done

                        # Archive original to NAS
                        if [ -d "$NAS_RECORDINGS" ]; then
                            mv "$audio_file" "$NAS_RECORDINGS/"
                            log "  ✓ Moved original to NAS: $filename"
                        else
                            log "  ⚠ NAS recordings directory not available"
                        fi
                    else
                        log_err "  Some chunks failed, cleaning up and keeping original"
                        # Clean up local chunks
                        for chunk_file in "${chunk_files[@]}"; do
                            rm -f "$chunk_file"
                        done
                        # Clean up staged chunks
                        for staged_chunk in "${staged_chunks[@]}"; do
                            rm -f "$staged_chunk"
                        done
                        continue
                    fi
                else
                    # Medium audio (10-30 min): Stage and transcribe single file remotely
                    log "  Staging audio to NAS..."
                    staged_path=$(stage_audio_to_nas "$audio_file")
                    if [[ -z "$staged_path" ]]; then
                        log_err "  Failed to stage audio"
                        continue
                    fi
                    log "  ✓ Staged: $(basename "$staged_path")"

                    log "  Transcribing remotely..."
                    hotwords=$(get_hotwords_context "$HOTWORDS_FILE")
                    output_basename="${timestamp}-${basename_no_ext}"
                    if ! run_remote_transcription "$filename" "$output_basename" "$hotwords"; then
                        log_err "  Remote transcription failed"
                        rm -f "$staged_path"  # Clean up staged file
                        continue
                    fi

                    log "  Collecting transcript..."
                    if ! collect_remote_transcript "$output_basename"; then
                        log_err "  Failed to collect transcript"
                        rm -f "$staged_path"  # Clean up staged file
                        continue
                    fi
                    log "  ✓ Transcription saved: ${output_basename}.json"

                    # Archive original to NAS, clean up staging
                    if [ -d "$NAS_RECORDINGS" ]; then
                        mv "$audio_file" "$NAS_RECORDINGS/"
                        log "  ✓ Moved to NAS: $filename"
                    else
                        log "  ⚠ NAS recordings directory not available"
                    fi
                    rm -f "$staged_path"
                    log "  ✓ Removed staged file"
                fi

                # Suspend remote host if configured
                suspend_remote

            else
                # REMOTE_ENABLED=false: Local fallback
                log "  Remote GPU disabled, using local transcription..."

                if [[ "$duration" -gt "$CHUNK_THRESHOLD" ]]; then
                    # Very long audio (> 30 min): Split and transcribe locally
                    log "  Audio is longer than 30 minutes, splitting into chunks..."

                    chunk_base="$INPUT_DIR/${basename_no_ext}"
                    chunks=$(split_audio_into_chunks "$audio_file" "$chunk_base" "$duration")

                    if [[ -z "$chunks" ]]; then
                        log_err "  Failed to create chunks"
                        continue
                    fi

                    # Transcribe each chunk locally
                    transcription_failed=false
                    chunk_files=()
                    for chunk_file in $chunks; do
                        chunk_basename=$(basename "$chunk_file" .mp3)
                        chunk_output="${output_base}_${chunk_basename##*_}"

                        log "  Transcribing chunk: $(basename "$chunk_file")..."
                        if "$PYTHON" -m mlx_audio.stt.generate \
                            --model "$selected_model" \
                            --audio "$chunk_file" \
                            --output-path "${chunk_output}" \
                            --format json \
                            --max-tokens "$MAX_TOKENS" \
                            ${context_args[@]+"${context_args[@]}"}; then
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
                        else
                            log "  ⚠ NAS not mounted, keeping files locally"
                        fi
                    else
                        log_err "  Some chunks failed to transcribe, keeping all files"
                        continue
                    fi
                else
                    # Medium audio (10-30 min): Transcribe locally
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
        fi

        log "  ✓ Done: $filename"
        echo ""
    done

    log "Transcription batch complete."

    sleep 1  # Brief pause before re-checking for new files
done
