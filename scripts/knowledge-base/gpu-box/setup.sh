#!/bin/bash
# Setup script for GPU box transcription worker
#
# This script installs the transcription worker and systemd service
# on the Ubuntu GPU box.
#
# Usage:
#   1. Copy this script and transcribe-worker.sh to the GPU box
#   2. Run: sudo ./setup.sh
#   3. Verify: systemctl status transcribe-worker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_SCRIPT="${SCRIPT_DIR}/transcribe-worker.sh"
SERVICE_FILE="${SCRIPT_DIR}/transcribe-worker.service"
INSTALL_DIR="/opt/openclaw"
SERVICE_INSTALL_PATH="/etc/systemd/system/transcribe-worker.service"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

echo "OpenClaw GPU Transcription Worker Setup"
echo "========================================"
echo ""

# Check dependencies
echo "Checking dependencies..."

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker not found. Install with:"
    echo "  curl -fsSL https://get.docker.com | sh"
    exit 1
fi
echo "  ✓ Docker"

if ! command -v ffmpeg &>/dev/null; then
    echo "ERROR: ffmpeg not found. Install with:"
    echo "  sudo apt-get install -y ffmpeg"
    exit 1
fi
echo "  ✓ ffmpeg"

if ! command -v nvidia-smi &>/dev/null; then
    echo "ERROR: nvidia-smi not found. Install NVIDIA drivers first."
    exit 1
fi
echo "  ✓ NVIDIA GPU drivers"

# Check NAS mount
if [[ ! -d "/mnt/nas" ]]; then
    echo "WARNING: NAS not mounted at /mnt/nas"
    echo "  Make sure to mount the NAS before starting the service"
else
    echo "  ✓ NAS mounted at /mnt/nas"
fi

# Check Docker image
if ! docker image inspect vibevoice-asr:latest &>/dev/null; then
    echo "WARNING: Docker image 'vibevoice-asr:latest' not found"
    echo "  Build the image before starting the service"
else
    echo "  ✓ Docker image: vibevoice-asr:latest"
fi

echo ""
echo "Installing worker script..."

# Create installation directory
mkdir -p "$INSTALL_DIR"

# Install worker script
if [[ ! -f "$WORKER_SCRIPT" ]]; then
    echo "ERROR: Worker script not found at $WORKER_SCRIPT"
    exit 1
fi

cp "$WORKER_SCRIPT" "${INSTALL_DIR}/transcribe-worker.sh"
chmod +x "${INSTALL_DIR}/transcribe-worker.sh"
echo "  ✓ Installed to ${INSTALL_DIR}/transcribe-worker.sh"

# Create log directory
mkdir -p /var/log/openclaw
chown xin:xin /var/log/openclaw
echo "  ✓ Created log directory: /var/log/openclaw"

echo ""
echo "Installing systemd service..."

# Install service file
if [[ ! -f "$SERVICE_FILE" ]]; then
    echo "ERROR: Service file not found at $SERVICE_FILE"
    exit 1
fi

cp "$SERVICE_FILE" "$SERVICE_INSTALL_PATH"
echo "  ✓ Installed to $SERVICE_INSTALL_PATH"

# Reload systemd
systemctl daemon-reload
echo "  ✓ Reloaded systemd"

# Enable service
systemctl enable transcribe-worker.service
echo "  ✓ Enabled service (will start on boot)"

echo ""
echo "Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Ensure NAS is mounted at /mnt/nas"
echo "  2. Ensure Docker image 'vibevoice-asr:latest' exists"
echo "  3. Start the service: sudo systemctl start transcribe-worker"
echo "  4. Check status: sudo systemctl status transcribe-worker"
echo "  5. View logs: sudo journalctl -u transcribe-worker -f"
echo ""
