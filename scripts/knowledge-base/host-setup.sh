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

# Fast local storage (SSD) - temporary audio only
echo "  Creating local recordings folder..."
mkdir -p ~/openclaw/media/recordings

# Google Drive (synced to cloud) - workspace + transcripts
echo "  Creating Google Drive folders..."
mkdir -p ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/workspace
mkdir -p ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/transcripts

# NAS (archival - audio only)
echo "  Creating NAS archival folder..."
if [ -d /Volumes/NAS_1/Xin ]; then
    mkdir -p /Volumes/NAS_1/Xin/openclaw/media/recordings
    echo "  ✓ NAS folder created (audio files will be moved here after transcription)"
else
    echo "  ⚠ NAS not mounted at /Volumes/NAS_1. Skipping NAS folder."
    echo "  Mount your NAS and run:"
    echo "    mkdir -p /Volumes/NAS_1/Xin/openclaw/media/recordings"
fi

# Scripts directory
echo "  Creating scripts folder..."
mkdir -p ~/openclaw/scripts

# Copy scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/transcribe.sh" ]; then
    cp "$SCRIPT_DIR/transcribe.sh" ~/openclaw/scripts/
    chmod +x ~/openclaw/scripts/transcribe.sh
    echo "Installed transcribe.sh to ~/openclaw/scripts/"
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
echo "  say 'Hello world' -o ~/openclaw/media/recordings/test.aiff"
echo "  ~/openclaw/scripts/transcribe.sh"
echo "  cat ~/Google\\ Drive/My\\ Drive/openclaw/transcripts/*test*.json"
echo ""
echo "For auto-transcription, install the launchd plist:"
echo "  cp scripts/knowledge-base/com.user.transcribe.plist ~/Library/LaunchAgents/"
echo "  # Edit the file to set YOUR_USERNAME"
echo "  launchctl load ~/Library/LaunchAgents/com.user.transcribe.plist"
echo ""
echo "Note: Audio files moved to NAS and transcripts saved to Google Drive after transcription"
echo ""
