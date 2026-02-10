#!/bin/bash
# Transcribe audio files with mlx-audio (VibeVoice-ASR)
#
# This script monitors ~/openclaw/media/recordings/ for new audio files and transcribes them
# using mlx-audio with Microsoft's VibeVoice-ASR model (includes speaker diarization).
# Transcripts are saved to ~/openclaw/transcripts/ (shared with VM), then synced to Google Drive.
# After successful transcription, audio files are moved to NAS for archival.
#
# Supported input formats: any format ffmpeg can decode (ogg, m4a, wav, mp3, flac, etc.)
# Files are converted to MP3 before transcription (miniaudio compatibility).
#
# Usage:
#   1. Drop audio files into ~/openclaw/media/recordings/
#   2. Run manually: ~/openclaw/scripts/transcribe.sh
#   3. Or auto-run via launchd (see setup guide)
#
# Requirements:
#   - mlx-audio (pip install mlx-audio)
#   - ffmpeg (brew install ffmpeg)
#   - rsync (built-in on macOS)
#   - Insync (Google Drive) mounted at ~/Insync/bac2qh@gmail.com/Google Drive (optional, for cloud sync)
#   - NAS mounted at /Volumes/NAS_1 (optional, files kept locally if not mounted)

set -euo pipefail

# Configuration
PYTHON="${HOME}/openclaw/scripts/.venv/bin/python"
INPUT_DIR="${HOME}/openclaw/media/recordings"
OUTPUT_DIR="${HOME}/openclaw/transcripts"
GDRIVE_TRANSCRIPTS="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/transcripts"
GDRIVE_WORKSPACE="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/workspace"
NAS_RECORDINGS="/Volumes/NAS_1/Xin/openclaw/media/recordings"
FAST_MODEL="mlx-community/whisper-large-v3-turbo-asr-fp16"
FULL_MODEL="mlx-community/VibeVoice-ASR-bf16"
MODEL_THRESHOLD=600  # Use FULL_MODEL if audio > 10 minutes (in seconds)
MAX_TOKENS=65536

# Chunking configuration (for long recordings)
CHUNK_THRESHOLD=3300 # Split if audio > 55 minutes (in seconds)
CHUNK_DURATION=3300  # 55 minutes per chunk (in seconds)
CHUNK_STEP=3000      # Start next chunk at 50 minutes (5 min overlap)

# Ensure directories exist
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

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

    echo "  Splitting into overlapping chunks (55 min each, 5 min overlap)..."

    while [[ $start_time -lt $duration ]]; do
        local chunk_file="${output_base}_part${chunk_num}.mp3"
        echo "    Creating chunk $chunk_num (start: ${start_time}s)..."

        if ffmpeg -y -i "$input_file" -ss "$start_time" -t "$CHUNK_DURATION" \
            -c:a libmp3lame -q:a 2 "$chunk_file" -loglevel warning; then
            chunks+=("$chunk_file")
            echo "    ✓ Chunk $chunk_num created"
        else
            echo "    Error: Failed to create chunk $chunk_num" >&2
            return 1
        fi

        ((chunk_num++))
        ((start_time += CHUNK_STEP))
    done

    echo "${chunks[@]}"
}

# Check dependencies
if ! "$PYTHON" -c "import mlx_audio" 2>/dev/null; then
    echo "Error: mlx-audio not found. Install with: pip install mlx-audio" >&2
    exit 1
fi

if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg not found. Install with: brew install ffmpeg" >&2
    exit 1
fi

# Process each audio file (any format ffmpeg supports)
shopt -s nullglob
for audio_file in "$INPUT_DIR"/*.ogg "$INPUT_DIR"/*.m4a "$INPUT_DIR"/*.wav "$INPUT_DIR"/*.mp3 "$INPUT_DIR"/*.flac "$INPUT_DIR"/*.aiff "$INPUT_DIR"/*.mp4 "$INPUT_DIR"/*.webm; do
    # Skip if no files match
    [ -e "$audio_file" ] || continue

    filename=$(basename "$audio_file")
    basename_no_ext="${filename%.*}"
    extension="${filename##*.}"
    timestamp=$(date +%Y-%m-%d-%H%M)
    output_base="$OUTPUT_DIR/${timestamp}-${basename_no_ext}"

    echo "Processing: $filename"

    # Convert to MP3 if not already (miniaudio only reliably supports mp3/wav/flac)
    if [[ "$extension" == "mp3" ]]; then
        mp3_file="$audio_file"
        converted=false
    else
        mp3_file="$INPUT_DIR/${basename_no_ext}.mp3"
        echo "  Converting to MP3..."
        if ffmpeg -y -i "$audio_file" -q:a 2 "$mp3_file" -loglevel warning; then
            echo "  ✓ Converted: ${basename_no_ext}.mp3"
            converted=true
        else
            echo "  Error: Conversion failed" >&2
            continue
        fi
    fi

    # Get audio duration
    duration=$(get_audio_duration "$mp3_file")
    if [[ -z "$duration" || "$duration" -eq 0 ]]; then
        echo "  Error: Could not determine audio duration" >&2
        continue
    fi

    duration_min=$((duration / 60))
    echo "  Duration: ${duration_min} minutes (${duration}s)"

    # Select model based on duration
    if [[ "$duration" -gt "$MODEL_THRESHOLD" ]]; then
        selected_model="$FULL_MODEL"
        echo "  Model: VibeVoice-ASR (long recording)"
    else
        selected_model="$FAST_MODEL"
        echo "  Model: whisper-turbo (short recording)"
    fi

    # Check if audio needs to be split into chunks
    if [[ "$duration" -gt "$CHUNK_THRESHOLD" ]]; then
        echo "  Audio is longer than 55 minutes, splitting into chunks..."

        # Split audio into chunks
        chunk_base="$INPUT_DIR/${basename_no_ext}"
        chunks=$(split_audio_into_chunks "$mp3_file" "$chunk_base" "$duration")

        if [[ -z "$chunks" ]]; then
            echo "  Error: Failed to create chunks" >&2
            continue
        fi

        # Transcribe each chunk
        transcription_failed=false
        chunk_files=()
        for chunk_file in $chunks; do
            chunk_basename=$(basename "$chunk_file" .mp3)
            chunk_output="${output_base}_${chunk_basename##*_}"  # Extract partN from filename

            echo "  Transcribing chunk: $(basename "$chunk_file")..."
            if "$PYTHON" -m mlx_audio.stt.generate \
                --model "$selected_model" \
                --audio "$chunk_file" \
                --output-path "${chunk_output}" \
                --format json \
                --max-tokens "$MAX_TOKENS"; then
                echo "    ✓ Chunk transcription saved: ${chunk_output}.json"
                chunk_files+=("$chunk_file")
            else
                echo "    Error: Chunk transcription failed" >&2
                transcription_failed=true
                break
            fi
        done

        # Clean up chunk files if all transcriptions succeeded
        if [[ "$transcription_failed" == false ]]; then
            echo "  ✓ All chunks transcribed successfully"
            for chunk_file in "${chunk_files[@]}"; do
                rm -f "$chunk_file"
                echo "  ✓ Cleaned up: $(basename "$chunk_file")"
            done

            # Move original audio to NAS
            if [ -d "$NAS_RECORDINGS" ]; then
                mv "$audio_file" "$NAS_RECORDINGS/"
                echo "  ✓ Moved to NAS: $filename"
                # Also move the converted MP3 if it was created
                if [[ "$converted" == true ]]; then
                    mv "$mp3_file" "$NAS_RECORDINGS/"
                    echo "  ✓ Moved to NAS: ${basename_no_ext}.mp3"
                fi
            else
                echo "  ⚠ NAS not mounted, keeping files locally"
            fi
        else
            echo "  Error: Some chunks failed to transcribe, keeping all files" >&2
            continue
        fi
    else
        # Audio is under threshold, transcribe as single file (existing behavior)
        echo "  Transcribing with VibeVoice-ASR (transcription + diarization)..."
        if "$PYTHON" -m mlx_audio.stt.generate \
            --model "$selected_model" \
            --audio "$mp3_file" \
            --output-path "${output_base}" \
            --format json \
            --max-tokens "$MAX_TOKENS"; then
            echo "  ✓ Transcription saved: ${output_base}.json"

            # Move audio files to NAS after successful transcription
            if [ -d "$NAS_RECORDINGS" ]; then
                mv "$audio_file" "$NAS_RECORDINGS/"
                echo "  ✓ Moved to NAS: $filename"
                # Also move the converted MP3 if it was created
                if [[ "$converted" == true ]]; then
                    mv "$mp3_file" "$NAS_RECORDINGS/"
                    echo "  ✓ Moved to NAS: ${basename_no_ext}.mp3"
                fi
            else
                echo "  ⚠ NAS not mounted, keeping files locally"
            fi
        else
            echo "  Error: Transcription failed" >&2
            continue
        fi
    fi

    echo "  ✓ Done: $filename"
    echo ""
done

echo "Transcription batch complete."

# Sync transcripts and workspace to Google Drive
if [ -d "$GDRIVE_TRANSCRIPTS" ] && [ -d "$GDRIVE_WORKSPACE" ]; then
    echo ""
    echo "Syncing to Google Drive..."

    # Sync transcripts
    if rsync -av --delete "$OUTPUT_DIR/" "$GDRIVE_TRANSCRIPTS/"; then
        echo "  ✓ Transcripts synced to Google Drive"
    else
        echo "  ⚠ Warning: Failed to sync transcripts to Google Drive" >&2
    fi

    # Sync workspace (if it exists)
    if [ -d "${HOME}/openclaw/workspace" ]; then
        if rsync -av --delete "${HOME}/openclaw/workspace/" "$GDRIVE_WORKSPACE/"; then
            echo "  ✓ Workspace synced to Google Drive"
        else
            echo "  ⚠ Warning: Failed to sync workspace to Google Drive" >&2
        fi
    fi
else
    echo "  ⚠ Google Drive not available, skipping cloud sync"
fi
