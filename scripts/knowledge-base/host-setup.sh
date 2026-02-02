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

# Install mlx-audio
echo "Installing mlx-audio..."
pip install mlx-audio

# Test mlx-audio
echo "Testing mlx-audio installation..."
if python -c "import mlx_audio" 2>/dev/null; then
    echo "  ✓ mlx-audio installed successfully"
    echo "  Note: VibeVoice-ASR model will auto-download on first use (~2GB)"
else
    echo "  ⚠ mlx-audio not found. You may need to:"
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
