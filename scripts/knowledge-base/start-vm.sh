#!/bin/bash
# Start Lume VM with symlinked shared folder
# Workaround for Lume CLI --shared-dir only accepting ONE folder

VM_NAME="${1:-nix}"
SHARE_DIR="$HOME/openclaw-share"

# Create symlink parent if needed
mkdir -p "$SHARE_DIR"

echo "Setting up shared folder symlinks..."

# Create symlinks (idempotent)
ln -sf "$HOME/openclaw/media/recordings" "$SHARE_DIR/recordings"
ln -sf "$HOME/Insync/bac2qh@gmail.com/Google Drive/openclaw/workspace" "$SHARE_DIR/workspace"
ln -sf "$HOME/Insync/bac2qh@gmail.com/Google Drive/openclaw/transcripts" "$SHARE_DIR/transcripts"

echo "  recordings  → $SHARE_DIR/recordings"
echo "  workspace   → $SHARE_DIR/workspace"
echo "  transcripts → $SHARE_DIR/transcripts"
echo ""

echo "Starting VM '$VM_NAME' with shared folder: $SHARE_DIR"
lume run "$VM_NAME" --shared-dir "$SHARE_DIR"
