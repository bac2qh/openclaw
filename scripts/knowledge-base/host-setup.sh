#!/bin/bash
# Host Setup Script for Personal Knowledge Base
#
# Run this on your Mac (host machine) to install transcription tools.
#
# Usage: USER_PROFILE=xin ./host-setup.sh
#
# Environment variables:
#   USER_PROFILE - User profile name (default: xin)

set -euo pipefail

# User profile
USER_PROFILE="${USER_PROFILE:-xin}"

# Validate USER_PROFILE contains only safe characters
if [[ ! "$USER_PROFILE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: USER_PROFILE must contain only alphanumeric characters, hyphens, and underscores" >&2
    exit 1
fi

BASE_DIR="${HOME}/openclaw/${USER_PROFILE}"

echo "=== Personal Knowledge Base - Host Setup ==="
echo "User profile: $USER_PROFILE"
echo ""

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install ffmpeg and wakeonlan
echo "Installing ffmpeg and wakeonlan..."
brew install ffmpeg wakeonlan

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

# User-specific directories
echo "  Creating user folders..."
mkdir -p "${BASE_DIR}/media/inbound"
mkdir -p "${BASE_DIR}/transcripts"
mkdir -p "${BASE_DIR}/workspace"
mkdir -p "${BASE_DIR}/config"

# Google Drive (synced to cloud) - workspace + transcripts
echo "  Creating Google Drive folders..."
mkdir -p ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/${USER_PROFILE}/workspace
mkdir -p ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/${USER_PROFILE}/transcripts

# NAS (archival - audio only, staging for remote GPU)
echo "  Creating NAS folders..."
if [ -d /Volumes/NAS_1 ]; then
    mkdir -p /Volumes/NAS_1/${USER_PROFILE}/openclaw/media/recordings
    mkdir -p /Volumes/NAS_1/${USER_PROFILE}/openclaw/media/staging
    mkdir -p /Volumes/NAS_1/${USER_PROFILE}/openclaw/media/staging/output
    echo "  ✓ NAS folders created:"
    echo "    - recordings/ (audio archival)"
    echo "    - staging/ (remote GPU input/output)"
else
    echo "  ⚠ NAS not mounted at /Volumes/NAS_1. Skipping NAS folders."
    echo "  Mount your NAS and run:"
    echo "    mkdir -p /Volumes/NAS_1/${USER_PROFILE}/openclaw/media/recordings"
    echo "    mkdir -p /Volumes/NAS_1/${USER_PROFILE}/openclaw/media/staging/output"
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
echo "  say 'Hello world' -o ${BASE_DIR}/media/inbound/test.aiff"
echo "  USER_PROFILE=${USER_PROFILE} ~/openclaw/scripts/transcribe.sh"
echo "  cat ~/Insync/bac2qh@gmail.com/Google\\ Drive/openclaw/${USER_PROFILE}/transcripts/*test*.json"
echo ""
echo "For auto-transcription, install the launchd plist:"
echo "  cp scripts/knowledge-base/com.user.transcribe-${USER_PROFILE}.plist ~/Library/LaunchAgents/"
echo "  launchctl load ~/Library/LaunchAgents/com.user.transcribe-${USER_PROFILE}.plist"
echo ""
echo "Note: Audio files moved to NAS and transcripts saved to Google Drive after transcription"
echo ""
echo "=== Remote GPU Transcription Setup ==="
echo ""
echo "To enable remote GPU transcription for long recordings (>10 min):"
echo ""
echo "1. On Ubuntu GPU box:"
echo "   - Install Docker with NVIDIA GPU support"
echo "   - Build Docker image: docker build -t vibevoice-asr:latest /path/to/dockerfile"
echo "   - Mount NAS at /mnt/nas (same NAS as Mac)"
echo "   - Enable passwordless sudo for systemctl suspend:"
echo "     sudo visudo"
echo "     # Add: ${USER_PROFILE} ALL=(ALL) NOPASSWD: /bin/systemctl suspend"
echo "   - Enable Wake-on-LAN in BIOS/UEFI"
echo "   - Get MAC address: ip link show"
echo ""
echo "2. On Mac, set environment variables before running transcribe.sh:"
echo "   export REMOTE_ENABLED=true"
echo "   export REMOTE_MAC_ADDR=AA:BB:CC:DD:EE:FF  # Ubuntu MAC address"
echo "   export REMOTE_HOST=gpu-box                # SSH hostname or IP"
echo "   export REMOTE_USER=${USER_PROFILE}"
echo "   export REMOTE_SSH_PORT=22"
echo ""
echo "3. Test WOL and SSH:"
echo "   wakeonlan AA:BB:CC:DD:EE:FF"
echo "   sleep 30"
echo "   ssh ${USER_PROFILE}@gpu-box 'docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi'"
echo ""
