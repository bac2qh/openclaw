#!/bin/bash
# Transcribe audio files with whisper.cpp + pyannote speaker diarization
#
# This script monitors ~/audio-inbox/ for new audio files, transcribes them
# using whisper.cpp with Metal GPU acceleration, adds speaker diarization
# using pyannote, and saves results to ~/transcripts/.
#
# Usage:
#   1. Drop audio files into ~/audio-inbox/
#   2. Run manually: ~/scripts/transcribe.sh
#   3. Or auto-run via launchd (see setup guide)
#
# Requirements:
#   - whisper-cpp (brew install whisper-cpp)
#   - ffmpeg (brew install ffmpeg)
#   - pyannote.audio (pip install pyannote.audio)
#   - HF_TOKEN environment variable

set -euo pipefail

# Configuration
INPUT_DIR="${HOME}/audio-inbox"
OUTPUT_DIR="${HOME}/transcripts"
ARCHIVE_DIR="${HOME}/audio-archive"
WHISPER_MODEL="${HOME}/.cache/whisper-cpp/ggml-large-v3.bin"
DIARIZE_SCRIPT="${HOME}/scripts/diarize.py"
DIARIZE_VENV="${HOME}/diarize-env"

# Ensure directories exist
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$ARCHIVE_DIR"

# Check dependencies
if ! command -v whisper-cpp &> /dev/null; then
    echo "Error: whisper-cpp not found. Install with: brew install whisper-cpp" >&2
    exit 1
fi

if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg not found. Install with: brew install ffmpeg" >&2
    exit 1
fi

if [ ! -f "$WHISPER_MODEL" ]; then
    echo "Error: Whisper model not found at $WHISPER_MODEL" >&2
    echo "Download with: whisper-cpp-download-model large-v3" >&2
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

    # Convert to 16-bit WAV (whisper.cpp requirement)
    wav_file="/tmp/${basename_no_ext}.wav"
    echo "  Converting to WAV..."
    if ! ffmpeg -y -i "$audio_file" -ar 16000 -ac 1 -c:a pcm_s16le "$wav_file" 2>/dev/null; then
        echo "  Error: Failed to convert $filename" >&2
        continue
    fi

    # Step 1: Transcribe with whisper.cpp
    echo "  Transcribing with whisper.cpp (Metal GPU)..."
    if whisper-cpp -m "$WHISPER_MODEL" -f "$wav_file" -otxt -of "$output_base" 2>/dev/null; then
        echo "  ✓ Transcription saved: ${output_base}.txt"
    else
        echo "  Error: Transcription failed" >&2
        rm -f "$wav_file"
        continue
    fi

    # Step 2: Diarize with pyannote (optional)
    if [ -f "$DIARIZE_SCRIPT" ] && [ -d "$DIARIZE_VENV" ] && [ -n "${HF_TOKEN:-}" ]; then
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
    rm -f "$wav_file"
    mv "$audio_file" "$ARCHIVE_DIR/"

    echo "  ✓ Done: $filename"
    echo ""
done

echo "Transcription batch complete."
