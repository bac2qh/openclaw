#!/bin/bash
# Sync NAS transcripts and Google Drive
#
# This script polls every 120 seconds and:
# 1. Pulls completed transcripts from NAS staging output → local transcripts/
# 2. Syncs local transcripts/ → Google Drive transcripts
# 3. Syncs local workspace/ → Google Drive workspace
#
# Uses rsync -rlt (additive only, no --delete) to prevent data loss.
# Skips metadata (permissions/owner/group) that Google Drive doesn't preserve.
#
# Usage:
#   Run as daemon in tmux: tmux new-session -d -s sync-xin '~/openclaw/scripts/knowledge-base/xin/sync.sh'
#
# Requirements:
#   - rsync (built-in on macOS)
#   - NAS mounted at /Volumes/NAS_1 (required for transcript collection)
#   - Insync (Google Drive) mounted at ~/Insync/bac2qh@gmail.com/Google Drive

set -euo pipefail

trap 'log "Shutting down..."; exit 0' SIGTERM SIGINT

BASE_DIR="${HOME}/openclaw/xin"
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
GDRIVE_TRANSCRIPTS="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/xin/transcripts"
GDRIVE_WORKSPACE="${HOME}/Insync/bac2qh@gmail.com/Google Drive/openclaw/xin/workspace"
NAS_OUTPUT="/Volumes/NAS_1/xin/openclaw/media/staging/output"

POLL_INTERVAL=120  # seconds between sync cycles
HEARTBEAT_INTERVAL=15  # log heartbeat every N cycles (~30 minutes)

# State tracking
cycle_count=0
nas_unavailable_logged=false

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
    ((cycle_count++))

    # Periodic heartbeat to show daemon is alive
    if (( cycle_count % HEARTBEAT_INTERVAL == 0 )); then
        log "⏱ Heartbeat: Cycle $cycle_count (daemon alive)"
    fi

    # Pull completed transcripts from NAS
    if [ -d "$NAS_OUTPUT" ]; then
        nas_unavailable_logged=false
        shopt -s nullglob
        json_files=("$NAS_OUTPUT"/*.json)
        if [[ ${#json_files[@]} -gt 0 ]]; then
            log "Found ${#json_files[@]} transcript(s) on NAS"
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
        if [ "$nas_unavailable_logged" = false ]; then
            log "⚠ NAS output directory not available: $NAS_OUTPUT"
            nas_unavailable_logged=true
        fi
    fi

    # Check if Google Drive directories are available
    if [ -d "$GDRIVE_TRANSCRIPTS" ] && [ -d "$GDRIVE_WORKSPACE" ]; then
        # Sync transcripts (additive only, no deletions)
        if [ -d "$TRANSCRIPTS_DIR" ]; then
            output=$(rsync -rlt --info=stats2 "$TRANSCRIPTS_DIR/" "$GDRIVE_TRANSCRIPTS/" 2>&1 || true)
            transferred=$(echo "$output" | grep -E 'Number of regular files transferred:' | awk '{print $NF}')
            if [[ "${transferred:-0}" -gt 0 ]]; then
                log "  ✓ Transcripts synced to Google Drive ($transferred file(s))"
            fi
        fi

        # Sync workspace (if it exists, additive only, no deletions)
        if [ -d "$WORKSPACE_DIR" ]; then
            output=$(rsync -rlt --info=stats2 "$WORKSPACE_DIR/" "$GDRIVE_WORKSPACE/" 2>&1 || true)
            transferred=$(echo "$output" | grep -E 'Number of regular files transferred:' | awk '{print $NF}')
            if [[ "${transferred:-0}" -gt 0 ]]; then
                log "  ✓ Workspace synced to Google Drive ($transferred file(s))"
            fi
        fi
    fi

    sleep "$POLL_INTERVAL"
done
