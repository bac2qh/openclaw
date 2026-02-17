#!/bin/bash
# Sync NAS transcripts and Google Drive
#
# This script polls every 120 seconds and:
# 1. Pulls completed transcripts from NAS staging output → local transcripts/
# 2. Syncs local transcripts/ → Google Drive transcripts
# 3. Syncs local workspace/ → Google Drive workspace
#
# Uses rsync -av (additive only, no --delete) to prevent data loss.
#
# Usage:
#   Run as daemon in tmux: tmux new-session -d -s sync-zhuoyue '~/openclaw/scripts/knowledge-base/zhuoyue/sync.sh'
#
# Requirements:
#   - rsync (built-in on macOS)
#   - NAS mounted at /Volumes/NAS_1 (required for transcript collection)
#   - Insync (Google Drive) mounted at ~/Insync/bac2qh@gmail.com/Google Drive

set -euo pipefail

trap 'log "Shutting down..."; exit 0' SIGTERM SIGINT

BASE_DIR="${HOME}/openclaw/zhuoyue"
LOG_DIR="${BASE_DIR}/logs"

# Create logs directory
mkdir -p "$LOG_DIR"

# Redirect stdout to log file with timestamps (tee to terminal and log)
exec 3>&1 4>&2
exec 1> >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"; done | tee -a "$LOG_DIR/sync.log" >&3)

# Redirect stderr to error log with timestamps (tee to terminal and log)
exec 2> >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"; done | tee -a "$LOG_DIR/sync.err" >&4)

# Configuration
TRANSCRIPTS_DIR="${BASE_DIR}/transcripts"
WORKSPACE_DIR="${BASE_DIR}/workspace"
GDRIVE_TRANSCRIPTS="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/zhuoyue/transcripts"
GDRIVE_WORKSPACE="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/zhuoyue/workspace"
NAS_OUTPUT="/Volumes/NAS_1/zhuoyue/openclaw/media/staging/output"

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

log "Sync daemon started (polling every ${POLL_INTERVAL}s)"

# Sync loop
while true; do
    log "Starting sync cycle..."

    # Pull completed transcripts from NAS
    if [ -d "$NAS_OUTPUT" ]; then
        shopt -s nullglob
        json_files=("$NAS_OUTPUT"/*.json)
        if [[ ${#json_files[@]} -gt 0 ]]; then
            log "  Found ${#json_files[@]} transcript(s) on NAS"
            for json_file in "${json_files[@]}"; do
                filename=$(basename "$json_file")
                if cp "$json_file" "$TRANSCRIPTS_DIR/$filename"; then
                    rm -f "$json_file"
                    log "  ✓ Collected transcript: $filename"
                else
                    log_err "  Failed to collect: $filename"
                fi
            done
        fi
    else
        log "  ⚠ NAS output directory not available: $NAS_OUTPUT"
    fi

    # Check if Google Drive directories are available
    if [ -d "$GDRIVE_TRANSCRIPTS" ] && [ -d "$GDRIVE_WORKSPACE" ]; then
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

    else
        log "  ⚠ Google Drive not available, skipping Google Drive sync"
    fi

    log "Sync cycle complete."

    sleep "$POLL_INTERVAL"
done
