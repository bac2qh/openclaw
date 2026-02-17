#!/bin/bash
# GPU Transcription Worker (Ubuntu 24.04)
#
# This script runs on the Ubuntu GPU box and polls NAS staging directories
# for audio files to transcribe. It processes files sequentially (single-threaded)
# to avoid GPU memory conflicts and race conditions.
#
# Data flow:
#   1. Polls /mnt/nas/{xin,zhuoyue}/openclaw/media/staging/ for audio files
#   2. Picks oldest file (by mtime) across all users
#   3. Loads hotwords from /mnt/nas/<user>/openclaw/config/hotwords.txt
#   4. Long files (>30 min): split into chunks with ffmpeg
#   5. Runs Docker transcription: docker run --rm --gpus all ...
#   6. On success: writes JSON to staging/output/, moves audio to recordings/
#   7. On failure: logs error, moves audio to staging/failed/
#   8. Idle logic: no files → check every 30s → after 5 min idle → shutdown
#
# Logging: /var/log/openclaw/transcribe-worker.log
#
# Managed by systemd: /etc/systemd/system/transcribe-worker.service

set -euo pipefail

# Configuration
NAS_BASE="/mnt/nas"
USERS=("xin" "zhuoyue")
DOCKER_IMAGE="vibevoice-asr:latest"
CHUNK_THRESHOLD=1800  # 30 minutes in seconds
CHUNK_DURATION=1800
CHUNK_STEP=1500       # 5 min overlap
POLL_INTERVAL=30      # seconds between checks when idle
IDLE_TIMEOUT=300      # 5 minutes in seconds
LOG_DIR="/var/log/openclaw"
LOG_FILE="${LOG_DIR}/transcribe-worker.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Logging helpers
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_err() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2
}

# Helper: Get audio duration using ffprobe
get_audio_duration() {
    local file="$1"
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null | cut -d. -f1
}

# Helper: Split audio into overlapping chunks
split_audio_into_chunks() {
    local input_file="$1"
    local output_dir="$2"
    local duration="$3"

    local chunk_num=1
    local start_time=0
    local chunks=()

    log "  Splitting into chunks (30 min each, 5 min overlap)..."

    while [[ $start_time -lt $duration ]]; do
        local padded_num
        printf -v padded_num "%02d" $chunk_num
        local chunk_file="${output_dir}/chunk_${padded_num}.mp3"
        log "    Creating chunk $chunk_num (start: ${start_time}s)..."

        if ffmpeg -y -i "$input_file" -ss "$start_time" -t "$CHUNK_DURATION" \
            -c:a libmp3lame -q:a 2 "$chunk_file" -loglevel warning 2>/dev/null; then
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

# Helper: Load hotwords from config file
get_hotwords() {
    local user="$1"
    local hotwords_file="${NAS_BASE}/${user}/openclaw/config/hotwords.txt"

    if [[ -f "$hotwords_file" ]]; then
        local context
        context=$(grep -v '^\s*#' "$hotwords_file" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//' | sed 's/,,*/,/g' | xargs)
        if [[ -n "$context" ]]; then
            echo "$context"
        fi
    fi
}

# Helper: Run Docker transcription
run_docker_transcription() {
    local mount_dir="$1"       # host directory to mount as /data
    local audio_file="$2"      # full host path to audio file
    local output_basename="$3"
    local hotwords="$4"

    # Derive container-relative path for audio
    local rel_path="${audio_file#$mount_dir/}"

    # Build Docker command
    local docker_cmd="docker run --rm --gpus all -v ${mount_dir}:/data ${DOCKER_IMAGE} --audio /data/${rel_path} --output-path /data/output/${output_basename} --format json"

    if [[ -n "$hotwords" ]]; then
        docker_cmd="${docker_cmd} --context \"${hotwords}\""
    fi

    # Run Docker
    if eval "$docker_cmd" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Helper: Find oldest audio file across all users
find_oldest_audio() {
    local oldest_file=""
    local oldest_time=999999999999

    for user in "${USERS[@]}"; do
        local staging_dir="${NAS_BASE}/${user}/openclaw/media/staging"
        if [[ ! -d "$staging_dir" ]]; then
            continue
        fi

        shopt -s nullglob
        for audio_file in "$staging_dir"/*.{ogg,m4a,mp3}; do
            if [[ -f "$audio_file" ]]; then
                local mtime=$(stat -c %Y "$audio_file" 2>/dev/null || stat -f %m "$audio_file" 2>/dev/null)
                if [[ $mtime -lt $oldest_time ]]; then
                    oldest_time=$mtime
                    oldest_file="$audio_file"
                fi
            fi
        done
    done

    echo "$oldest_file"
}

# Check dependencies
if ! command -v docker &>/dev/null; then
    log_err "Docker not found"
    exit 1
fi

if ! command -v ffmpeg &>/dev/null; then
    log_err "ffmpeg not found"
    exit 1
fi

if ! command -v nvidia-smi &>/dev/null; then
    log_err "nvidia-smi not found (GPU drivers not installed?)"
    exit 1
fi

if [[ ! -d "$NAS_BASE" ]]; then
    log_err "NAS not mounted at $NAS_BASE"
    exit 1
fi

log "GPU Transcription Worker started"

# Main processing loop
idle_start=""

while true; do
    # Find oldest audio file
    audio_file=$(find_oldest_audio)

    if [[ -z "$audio_file" ]]; then
        # No files to process
        if [[ -z "$idle_start" ]]; then
            idle_start=$(date +%s)
            log "No files to process, entering idle mode"
        else
            idle_elapsed=$(($(date +%s) - idle_start))
            if [[ $idle_elapsed -ge $IDLE_TIMEOUT ]]; then
                log "Idle timeout reached (${IDLE_TIMEOUT}s), shutting down"
                sudo shutdown now
                exit 0
            fi
        fi

        sleep "$POLL_INTERVAL"
        continue
    fi

    # Reset idle timer (we have work to do)
    idle_start=""

    # Determine user from path
    user=""
    for u in "${USERS[@]}"; do
        if [[ "$audio_file" =~ $NAS_BASE/$u/ ]]; then
            user="$u"
            break
        fi
    done

    if [[ -z "$user" ]]; then
        log_err "Could not determine user from path: $audio_file"
        continue
    fi

    filename=$(basename "$audio_file")
    staging_dir="${NAS_BASE}/${user}/openclaw/media/staging"
    output_dir="${staging_dir}/output"
    recordings_dir="${NAS_BASE}/${user}/openclaw/media/recordings"
    failed_dir="${staging_dir}/failed"
    timestamp=$(date +%Y-%m-%d-%H%M)
    basename_no_ext="${filename%.*}"
    output_basename="${timestamp}-${basename_no_ext}"

    log "Processing: $filename (user: $user)"

    # Create output directories
    mkdir -p "$output_dir" "$recordings_dir" "$failed_dir"

    # Get audio duration
    duration=$(get_audio_duration "$audio_file")
    if [[ -z "$duration" || "$duration" -eq 0 ]]; then
        log_err "  Could not determine audio duration"
        mv "$audio_file" "$failed_dir/"
        log "  Moved to failed: $filename"
        continue
    fi

    duration_min=$((duration / 60))
    log "  Duration: ${duration_min} minutes (${duration}s)"

    # Load hotwords
    hotwords=$(get_hotwords "$user")
    if [[ -n "$hotwords" ]]; then
        log "  Hotwords: $hotwords"
    fi

    # Process based on duration
    if [[ "$duration" -gt "$CHUNK_THRESHOLD" ]]; then
        log "  Long audio detected, splitting into chunks..."

        chunks_dir="${staging_dir}/chunks"
        mkdir -p "$chunks_dir"

        chunks=$(split_audio_into_chunks "$audio_file" "$chunks_dir" "$duration")
        if [[ -z "$chunks" ]]; then
            log_err "  Failed to create chunks"
            rm -rf "$chunks_dir"
            mv "$audio_file" "$failed_dir/"
            log "  Moved to failed: $filename"
            continue
        fi

        transcription_failed=false
        chunk_num=1

        for chunk_file in $chunks; do
            local padded_num
            printf -v padded_num "%02d" $chunk_num
            chunk_output="${output_basename}_part${padded_num}"
            log "  Transcribing chunk $chunk_num..."

            if ! run_docker_transcription "$staging_dir" "$chunk_file" "$chunk_output" "$hotwords"; then
                log_err "  Chunk $chunk_num transcription failed"
                transcription_failed=true
                break
            fi

            log "  ✓ Chunk $chunk_num complete: ${chunk_output}.json"
            ((chunk_num++))
        done

        # Clean up chunks (always, regardless of success/failure)
        rm -rf "$chunks_dir"
        log "  ✓ Chunks cleaned up"

        if [[ "$transcription_failed" == true ]]; then
            mv "$audio_file" "$failed_dir/"
            log "  Moved to failed: $filename"
            continue
        fi

        log "  ✓ All chunks transcribed successfully"
    else
        log "  Transcribing..."

        if ! run_docker_transcription "$staging_dir" "$audio_file" "$output_basename" "$hotwords"; then
            log_err "  Transcription failed"
            mv "$audio_file" "$failed_dir/"
            log "  Moved to failed: $filename"
            continue
        fi

        log "  ✓ Transcription complete: ${output_basename}.json"
    fi

    # Move audio to recordings
    mv "$audio_file" "$recordings_dir/"
    log "  ✓ Moved to recordings: $filename"

    log "  ✓ Done: $filename"
    echo ""
done
