#!/bin/bash
# Transcribe audio files with mlx-audio (VibeVoice-ASR)
#
# This script monitors ~/openclaw_media/recordings/ for new audio files and transcribes them
# using mlx-audio with Microsoft's VibeVoice-ASR model (includes speaker diarization).
# Transcripts are saved to Google Drive for cloud sync.
# After successful transcription, audio files are moved to NAS for archival.
#
# Usage:
#   1. Drop audio files into ~/openclaw_media/recordings/
#   2. Run manually: ~/scripts/transcribe.sh
#   3. Or auto-run via launchd (see setup guide)
#
# Requirements:
#   - mlx-audio (pip install mlx-audio)
#   - ffmpeg (brew install ffmpeg)
#   - Google Drive mounted at ~/Google Drive/My Drive
#   - NAS mounted at /Volumes/NAS_1 (optional, files kept locally if not mounted)

set -euo pipefail

# Configuration
INPUT_DIR="${HOME}/openclaw_media/recordings"
OUTPUT_DIR="${HOME}/Google Drive/My Drive/openclaw_agent/transcripts"
NAS_RECORDINGS="/Volumes/NAS_1/Xin/openclaw_agent/recordings"
VIBEVOICE_MODEL="mlx-community/VibeVoice-ASR-bf16"
MAX_TOKENS=8192

# Ensure directories exist
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

# Check dependencies
if ! python -c "import mlx_audio" 2>/dev/null; then
    echo "Error: mlx-audio not found. Install with: pip install mlx-audio" >&2
    exit 1
fi

if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg not found. Install with: brew install ffmpeg" >&2
    exit 1
fi

# Process each audio file
shopt -s nullglob
for audio_file in "$INPUT_DIR"/*.mp3 "$INPUT_DIR"/*.m4a "$INPUT_DIR"/*.wav "$INPUT_DIR"/*.mp4 "$INPUT_DIR"/*.ogg "$INPUT_DIR"/*.aiff; do
    # Skip if no files match
    [ -e "$audio_file" ] || continue

    filename=$(basename "$audio_file")
    basename_no_ext="${filename%.*}"
    timestamp=$(date +%Y-%m-%d-%H%M)
    output_base="$OUTPUT_DIR/${timestamp}-${basename_no_ext}"

    echo "Processing: $filename"

    # Transcribe with VibeVoice-ASR (includes speaker diarization)
    echo "  Transcribing with VibeVoice-ASR (transcription + diarization)..."
    if python -m mlx_audio.stt.generate \
        --model "$VIBEVOICE_MODEL" \
        --audio "$audio_file" \
        --output-path "$OUTPUT_DIR" \
        --output-name "${timestamp}-${basename_no_ext}" \
        --format json \
        --max-tokens "$MAX_TOKENS" \
        --temperature 0.0 2>/dev/null; then
        echo "  ✓ Transcription saved: ${output_base}.json"

        # Move audio to NAS after successful transcription
        if [ -d "$NAS_RECORDINGS" ]; then
            mv "$audio_file" "$NAS_RECORDINGS/"
            echo "  ✓ Moved to NAS: $filename"
        else
            echo "  ⚠ NAS not mounted, keeping file locally"
        fi
    else
        echo "  Error: Transcription failed" >&2
        continue
    fi

    echo "  ✓ Done: $filename"
    echo ""
done

echo "Transcription batch complete."
