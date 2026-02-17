#!/bin/bash
# Sync transcripts and workspace to Google Drive
#
# This script polls every 120 seconds and syncs:
# - ~/openclaw/xin/transcripts/ → Google Drive transcripts
# - ~/openclaw/xin/workspace/ → Google Drive workspace
#
# Uses rsync -av (additive only, no --delete) to prevent data loss.
#
# Usage:
#   Run as daemon in tmux: tmux new-session -d -s sync-gdrive-xin '~/openclaw/scripts/knowledge-base/xin/sync-gdrive.sh'
#
# Requirements:
#   - rsync (built-in on macOS)
#   - Insync (Google Drive) mounted at ~/Insync/bac2qh@gmail.com/Google Drive

set -euo pipefail

trap 'log "Shutting down..."; exit 0' SIGTERM SIGINT

BASE_DIR="${HOME}/openclaw/xin"
LOG_DIR="${BASE_DIR}/logs"

# Create logs directory
mkdir -p "$LOG_DIR"

# Redirect stdout to log file with timestamps (tee to terminal and log)
exec 3>&1 4>&2
exec 1> >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"; done | tee -a "$LOG_DIR/sync-gdrive.log" >&3)

# Redirect stderr to error log with timestamps (tee to terminal and log)
exec 2> >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"; done | tee -a "$LOG_DIR/sync-gdrive.err" >&4)

# Configuration
TRANSCRIPTS_DIR="${BASE_DIR}/transcripts"
WORKSPACE_DIR="${BASE_DIR}/workspace"
GDRIVE_TRANSCRIPTS="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/xin/transcripts"
GDRIVE_WORKSPACE="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/xin/workspace"

POLL_INTERVAL=120  # seconds between sync cycles

# Logging helpers
log() {
    echo "$*"
}

log_err() {
    echo "ERROR: $*" >&2
}

# Check rsync availability
if ! command -v rsync &> /dev/null; then
    log_err "rsync not found"
    exit 1
fi

log "Google Drive sync daemon started (polling every ${POLL_INTERVAL}s)"

# Sync loop
while true; do
    # Check if Google Drive directories are available
    if [ -d "$GDRIVE_TRANSCRIPTS" ] && [ -d "$GDRIVE_WORKSPACE" ]; then
        log "Starting sync cycle..."

        # Sync transcripts (additive only, no deletions)
        if [ -d "$TRANSCRIPTS_DIR" ]; then
            if rsync -av "$TRANSCRIPTS_DIR/" "$GDRIVE_TRANSCRIPTS/"; then
                log "  ✓ Transcripts synced to Google Drive"
            else
                log_err "  ⚠ Warning: Failed to sync transcripts to Google Drive"
            fi
        else
            log "  ⚠ Transcripts directory not found: $TRANSCRIPTS_DIR"
        fi

        # Sync workspace (if it exists, additive only, no deletions)
        if [ -d "$WORKSPACE_DIR" ]; then
            if rsync -av "$WORKSPACE_DIR/" "$GDRIVE_WORKSPACE/"; then
                log "  ✓ Workspace synced to Google Drive"
            else
                log_err "  ⚠ Warning: Failed to sync workspace to Google Drive"
            fi
        else
            log "  ⚠ Workspace directory not found (will be created when needed): $WORKSPACE_DIR"
        fi

        log "Sync cycle complete."
    else
        log "  ⚠ Google Drive not available, skipping sync cycle"
    fi

    sleep "$POLL_INTERVAL"
done
