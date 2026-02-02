#!/bin/bash
# Transcribe audio files with mlx-whisper + pyannote speaker diarization
#
# This script monitors ~/audio-inbox/ for new audio files, transcribes them
# using mlx-whisper (Apple MLX framework), adds speaker diarization
# using pyannote, and saves results to ~/transcripts/.
#
# Usage:
#   1. Drop audio files into ~/audio-inbox/
#   2. Run manually: ~/scripts/transcribe.sh
#   3. Or auto-run via launchd (see setup guide)
#
# Requirements:
#   - mlx-whisper (pip install mlx-whisper)
#   - ffmpeg (brew install ffmpeg)
#   - pyannote.audio (pip install pyannote.audio)
#   - HF_TOKEN environment variable (for pyannote only)

set -euo pipefail

# Configuration
INPUT_DIR="${HOME}/audio-inbox"
OUTPUT_DIR="${HOME}/transcripts"
ARCHIVE_DIR="${HOME}/audio-archive"
WHISPER_MODEL="mlx-community/whisper-large-v3-mlx"  # MLX model from HuggingFace
DIARIZE_SCRIPT="${HOME}/scripts/diarize.py"
DIARIZE_VENV="${HOME}/diarize-env"

# Ensure directories exist
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$ARCHIVE_DIR"

# Check dependencies
if ! command -v mlx_whisper &> /dev/null; then
    echo "Error: mlx_whisper not found. Install with: pip install mlx-whisper" >&2
    exit 1
fi

if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg not found. Install with: brew install ffmpeg" >&2
    exit 1
fi

if [ ! -f "$DIARIZE_SCRIPT" ]; then
    echo "Warning: Diarization script not found at $DIARIZE_SCRIPT" >&2
    echo "Speaker diarization will be skipped." >&2
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

    # Step 1: Transcribe with mlx-whisper
    echo "  Transcribing with mlx-whisper (Apple MLX)..."
    if mlx_whisper "$audio_file" --model "$WHISPER_MODEL" --output-dir "$OUTPUT_DIR" --output-name "${timestamp}-${basename_no_ext}" 2>/dev/null; then
        echo "  ✓ Transcription saved: ${output_base}.txt"
    else
        echo "  Error: Transcription failed" >&2
        continue
    fi

    # Convert for diarization if needed (pyannote requires WAV)
    wav_file="/tmp/${basename_no_ext}.wav"
    if [ -f "$DIARIZE_SCRIPT" ] && [ -d "$DIARIZE_VENV" ] && [ -n "${HF_TOKEN:-}" ]; then
        echo "  Converting to WAV for diarization..."
        if ! ffmpeg -y -i "$audio_file" -ar 16000 -ac 1 -c:a pcm_s16le "$wav_file" 2>/dev/null; then
            echo "  Warning: Conversion for diarization failed" >&2
            wav_file=""
        fi
    fi

    # Step 2: Diarize with pyannote (optional)
    if [ -n "$wav_file" ] && [ -f "$wav_file" ]; then
        echo "  Diarizing with pyannote..."
        # shellcheck disable=SC1091
        if source "$DIARIZE_VENV/bin/activate" && \
           python "$DIARIZE_SCRIPT" "$wav_file" "${output_base}.speakers.txt" 2>/dev/null; then
            echo "  ✓ Diarization saved: ${output_base}.speakers.txt"
        else
            echo "  Warning: Diarization failed (continuing anyway)" >&2
        fi
    else
        echo "  Skipping diarization (not configured)"
    fi

    # Cleanup
    if [ -n "$wav_file" ] && [ -f "$wav_file" ]; then
        rm -f "$wav_file"
    fi
    mv "$audio_file" "$ARCHIVE_DIR/"

    echo "  ✓ Done: $filename"
    echo ""
done

echo "Transcription batch complete."
