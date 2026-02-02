#!/bin/bash
# Host Setup Script for Personal Knowledge Base
#
# Run this on your Mac (host machine) to install transcription tools.
#
# Usage: ./host-setup.sh

set -euo pipefail

echo "=== Personal Knowledge Base - Host Setup ==="
echo ""

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install ffmpeg
echo "Installing ffmpeg..."
brew install ffmpeg

# Install mlx-whisper
echo "Installing mlx-whisper..."
pip install mlx-whisper

# Test mlx-whisper
echo "Testing mlx-whisper installation..."
if command -v mlx_whisper &> /dev/null; then
    echo "  ✓ mlx-whisper installed successfully"
    echo "  Note: Model will auto-download on first use (~3GB)"
else
    echo "  ⚠ mlx-whisper not found in PATH. You may need to:"
    echo "    export PATH=\"\$HOME/Library/Python/3.x/bin:\$PATH\""
fi

# Create directories
echo "Creating directories..."
mkdir -p ~/audio-inbox
mkdir -p ~/transcripts
mkdir -p ~/audio-archive
mkdir -p ~/scripts

# Copy scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/transcribe.sh" ]; then
    cp "$SCRIPT_DIR/transcribe.sh" ~/scripts/
    chmod +x ~/scripts/transcribe.sh
    echo "Installed transcribe.sh to ~/scripts/"
fi

if [ -f "$SCRIPT_DIR/diarize.py" ]; then
    cp "$SCRIPT_DIR/diarize.py" ~/scripts/
    chmod +x ~/scripts/diarize.py
    echo "Installed diarize.py to ~/scripts/"
fi

# Setup pyannote (optional)
echo ""
echo "=== pyannote Setup (Optional) ==="
read -p "Install pyannote for speaker diarization? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Creating Python virtual environment..."
    python3 -m venv ~/diarize-env
    source ~/diarize-env/bin/activate

    echo "Installing pyannote.audio..."
    pip install pyannote.audio torch torchaudio

    echo ""
    echo "pyannote installed. You need to:"
    echo "1. Create Hugging Face account: https://huggingface.co/"
    echo "2. Accept model terms:"
    echo "   - https://huggingface.co/pyannote/speaker-diarization-3.1"
    echo "   - https://huggingface.co/pyannote/segmentation-3.0"
    echo "3. Create token: https://huggingface.co/settings/tokens"
    echo "4. Set environment variable: export HF_TOKEN='hf_...'"
fi

# Install Lume (optional)
echo ""
echo "=== Lume VM Setup (Optional) ==="
read -p "Install Lume for VM-based OpenClaw? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Installing Lume..."
    brew install lume
    echo ""
    echo "Lume installed. Next steps:"
    echo "1. Create VM: lume create memory-app --os ubuntu --cpu 4 --memory 8192"
    echo "2. Configure shared folder in ~/.lume/vms/memory-app/config.yaml"
    echo "3. Start VM: lume start memory-app"
    echo "4. SSH in: lume ssh memory-app"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Test transcription:"
echo "  say 'Hello world' -o ~/audio-inbox/test.aiff"
echo "  ~/scripts/transcribe.sh"
echo "  cat ~/transcripts/*test*.txt"
echo ""
echo "For auto-transcription, install the launchd plist:"
echo "  cp scripts/knowledge-base/com.user.transcribe.plist ~/Library/LaunchAgents/"
echo "  # Edit the file to set YOUR_USERNAME and HF_TOKEN"
echo "  launchctl load ~/Library/LaunchAgents/com.user.transcribe.plist"
echo ""
