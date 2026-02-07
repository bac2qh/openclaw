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
VIBEVOICE_MODEL="mlx-community/VibeVoice-ASR-bf16"
MAX_TOKENS=8192

# Ensure directories exist
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

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

    # Transcribe with VibeVoice-ASR (includes speaker diarization)
    echo "  Transcribing with VibeVoice-ASR (transcription + diarization)..."
    if "$PYTHON" -m mlx_audio.stt.generate \
        --model "$VIBEVOICE_MODEL" \
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
