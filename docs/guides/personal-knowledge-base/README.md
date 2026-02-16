# Personal Knowledge Base with OpenClaw

Build a voice-powered memory system using OpenClaw, mlx-audio (VibeVoice), Lume VM, and Kimi 2.5.

## Quick Start

**What you'll build:**
- Voice memos via Telegram → auto-transcribed → searchable memory
- Meeting recordings → transcribed with speaker labels → indexed
- Natural language queries: "What did we decide about the API?"
- Reminders: "Remind me tomorrow at 9am about the standup"

**Total setup time:** ~30 minutes
**Monthly cost:** ~$6 (LLM API only - transcription is 100% local)

---

## Multi-User Setup

The system supports multiple users on the same Mac host and VM. Each user gets isolated:
- Telegram bot and agent
- Media inbound folder, transcripts, workspace, config
- Memory database (per agent)

**Directory structure:**
```
~/openclaw/
├── xin/                        # User 1's data
│   ├── media/inbound/
│   ├── transcripts/
│   ├── workspace/
│   └── config/
├── zhuoyue/                    # User 2's data
│   ├── media/inbound/
│   ├── transcripts/
│   ├── workspace/
│   └── config/
└── scripts/knowledge-base/     # Scripts
    ├── xin/                    # Xin's scripts (hardcoded paths)
    │   ├── transcribe.sh
    │   ├── transcript-watcher.sh
    │   ├── backup.sh
    │   ├── host-setup.sh
    │   └── com.user.transcribe-xin.plist
    ├── zhuoyue/                # Zhuoyue's scripts (hardcoded paths)
    │   ├── transcribe.sh
    │   ├── transcript-watcher.sh
    │   ├── backup.sh
    │   ├── host-setup.sh
    │   └── com.user.transcribe-zhuoyue.plist
    └── .venv/                  # Shared Python environment
```

**Key points:**
- Each user has their own script copies with hardcoded paths (no `USER_PROFILE` env var needed)
- VM runs two separate OpenClaw instances with different `OPENCLAW_STATE_DIR` values
- Each instance has its own gateway port (18789 for user 1, 18790 for user 2)
- No data cross-contamination between users
- Google Drive and NAS paths also use per-user subdirectories

**For single-user setup:** Follow the guide as written, using the `xin/` script directory. Skip the rest of this section.

### Agent Routing (VM)

Route Telegram messages to per-user agents using the `bindings` config. Each user's DMs go to a dedicated agent with an isolated workspace and memory database.

```yaml
# ~/.openclaw/config.yml
bindings:
  - agentId: "xin"
    match:
      channel: "telegram"
      peer:
        kind: "direct"
        id: "123456789"        # Xin's Telegram chat ID
  - agentId: "zhuoyue"
    match:
      channel: "telegram"
      peer:
        kind: "direct"
        id: "987654321"        # Zhuoyue's Telegram chat ID

session:
  dmScope: "per-peer"          # Isolate conversation history per user
```

**CLI equivalent:**

```bash
openclaw config set bindings '[
  {
    "agentId": "xin",
    "match": { "channel": "telegram", "peer": {"kind": "direct", "id": "123456789"} }
  },
  {
    "agentId": "zhuoyue",
    "match": { "channel": "telegram", "peer": {"kind": "direct", "id": "987654321"} }
  }
]'

openclaw config set session.dmScope per-peer
```

Routing matches in order: peer ID (chat ID) → account ID → channel wildcard → default agent.

### Separate Gateway Instances

Each user runs their own OpenClaw gateway with isolated state:

```bash
# User 1 (xin) — port 18789
OPENCLAW_STATE_DIR=~/.openclaw-xin \
  nohup openclaw gateway run --bind loopback --port 18789 --force \
  > /tmp/openclaw-gateway-xin.log 2>&1 &

# User 2 (zhuoyue) — port 18790
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue \
  nohup openclaw gateway run --bind loopback --port 18790 --force \
  > /tmp/openclaw-gateway-zhuoyue.log 2>&1 &
```

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│ M1 Pro Mac (Host)                                                        │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ Unified Shared Folder: ~/openclaw/ (shared with VM via VirtioFS)│    │
│  │ ├── media/recordings/   ← Audio lands here (temporary)          │    │
│  │ ├── transcripts/        ← mlx-audio writes transcripts here     │    │
│  │ └── workspace/          ← Markdown files (synced to cloud)      │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                        ↓ launchd watches recordings                     │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ mlx-audio (VibeVoice-ASR)                                         │  │
│  │ Transcription + diarization - Runs on Metal GPU (100% local)     │  │
│  │ → Writes to ~/openclaw/transcripts/                               │  │
│  │ → Syncs to Google Drive (workspace + transcripts)                │  │
│  │ → Moves audio to NAS                                              │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌──────────────────────────┐                                           │
│  │ Lume VM                  │                                           │
│  │ /Volumes/My Shared Files/│  ← VirtioFS mount of ~/openclaw/         │
│  │ ├── media/recordings/    │  ← Telegram audio lands here            │
│  │ ├── transcripts/         │  ← Host writes transcripts, VM reads    │
│  │ └── workspace/           │  ← Agent reads/writes markdown          │
│  │                          │                                           │
│  │ ┌──────────────────────┐ │                                           │
│  │ │ OpenClaw             │ │                                           │
│  │ │ ├── Telegram Bot     │ │                                           │
│  │ │ ├── Memory System    │ │                                           │
│  │ │ └── Kimi 2.5         │ │                                           │
│  │ └──────────────────────┘ │                                           │
│  └──────────────────────────┘                                           │
│                                                                          │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ Google Drive (cloud backup - rsync after transcription)          │  │
│  │ ~/Insync/bac2qh@gmail.com/Google Drive/openclaw/                 │  │
│  │ ├── workspace/          (markdown files)                          │  │
│  │ └── transcripts/        (JSON transcripts)                        │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ NAS (permanent audio storage)                                     │  │
│  │ /Volumes/NAS_1/Xin/openclaw/media/                                │  │
│  │ └── recordings/    (audio moved here after transcription)         │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

## File Organization

**What goes where:**

| Location | Contents | Lifecycle | Why |
|----------|----------|-----------|-----|
| ~/openclaw/media/ (SSD) | Recordings (temporary) | Audio → NAS after transcription | Fast local storage |
| Google Drive | Markdown workspace + transcripts | Cloud sync | Knowledge persistence |
| NAS | Archived audio only | Permanent storage | Long-term audio archival |
| VM only | Databases, config, sessions | Not synced | Rebuildable |

**Host Mac paths:**
```
~/openclaw/                       # Single unified shared folder
├── media/
│   └── recordings/               # Telegram voice messages (temporary - moved to NAS)
├── workspace/                    # Markdown files (synced to Google Drive)
│   ├── MEMORY.md
│   └── notes/
├── transcripts/                  # mlx-audio JSON outputs (synced to Google Drive)
└── scripts/
    └── transcribe.sh             # mlx-audio transcription + sync + NAS archival

~/Insync/bac2qh@gmail.com/Google Drive/openclaw/
├── workspace/                    # Cloud backup of workspace (rsync after transcription)
└── transcripts/                  # Cloud backup of transcripts (rsync after transcription)

/Volumes/NAS_1/Xin/openclaw/media/
└── recordings/                   # Archived audio (moved here after transcription)
```

**VM paths:**
```
~/.openclaw/                                    # Stays in VM (databases, config)
├── config.yaml
├── sessions/
├── agents/                                     # SQLite databases
└── workspace -> /Volumes/My Shared Files/workspace  # Symlink to shared folder

/Volumes/My Shared Files/                       # VirtioFS mount of ~/openclaw/
├── media/
│   └── recordings/                             # Telegram audio lands here
├── transcripts/                                # Host writes transcripts, VM reads
└── workspace/                                  # Agent reads/writes markdown
```

---

## Table of Contents

1. [Host Setup (Mac)](#part-1-host-setup-mac)
2. [Lume VM Setup](#part-2-lume-vm-setup)
3. [OpenClaw Setup (VM)](#part-3-openclaw-setup-vm)
4. [Telegram Bot](#part-4-telegram-bot-setup)
5. [Async Transcription Pipeline](#part-5-async-transcription-pipeline)
6. [Backup and Sync Strategy](#part-6-backup-and-sync-strategy)
7. [Troubleshooting](#troubleshooting)
8. [Audio Flow Details](./telegram-audio-flow.md) - Technical documentation of audio flows

---

## Part 1: Host Setup (Mac)

### 1.1 Install Lume

```bash
# Install Lume CLI
brew install lume

# Verify
lume --version
```

### 1.2 Install mlx-audio with VibeVoice (Transcription + Diarization)

mlx-audio with Microsoft's VibeVoice-ASR provides both transcription AND speaker diarization in one model, running natively on M1/M2/M3 via Apple's MLX framework.

```bash
# Install ffmpeg (required for audio conversion)
brew install ffmpeg

# Install mlx-audio
pip install mlx-audio

# Test it works
say "Hello, this is a test of the transcription system." -o /tmp/test.aiff
ffmpeg -y -i /tmp/test.aiff /tmp/test.mp3 2>/dev/null
python -m mlx_audio.stt.generate \
    --model mlx-community/VibeVoice-ASR-bf16 \
    --audio /tmp/test.mp3 \
    --format json \
    --max-tokens 8192
```

**Expected output:**
JSON with transcription, timestamps, and speaker labels.

**Why VibeVoice?**
- Transcription + speaker diarization in one model (no separate pyannote needed)
- Timestamps for each segment
- Optimized for long-form audio (meetings)
- Runs 100% locally on Apple Silicon

**Python API example:**

```python
from mlx_audio.stt.utils import load

model = load("mlx-community/VibeVoice-ASR-bf16")
result = model.generate(audio="meeting.wav", max_tokens=8192, temperature=0.0)

# Access parsed segments with timing and speakers
for seg in result.segments:
    print(f"[{seg['start_time']:.1f}-{seg['end_time']:.1f}] Speaker {seg['speaker_id']}: {seg['text']}")
```

### 1.3 Install Scripts

No script installation needed - scripts remain in the repo directory with per-user subdirectories (`scripts/knowledge-base/xin/` and `scripts/knowledge-base/zhuoyue/`).

```bash
# Scripts are already organized per-user in:
# scripts/knowledge-base/xin/transcribe.sh
# scripts/knowledge-base/zhuoyue/transcribe.sh
```

### 1.4 Create Directories

```bash
# Unified shared folder structure (per-user)
# Replace 'xin' with your username (or 'zhuoyue' for second user)
USER_NAME="xin"

mkdir -p ~/openclaw/${USER_NAME}/media/inbound
mkdir -p ~/openclaw/${USER_NAME}/workspace
mkdir -p ~/openclaw/${USER_NAME}/transcripts
mkdir -p ~/openclaw/${USER_NAME}/config

# Google Drive destinations (cloud backup, per-user)
mkdir -p ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/${USER_NAME}/workspace
mkdir -p ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/${USER_NAME}/transcripts

# NAS (archival - audio only, per-user)
mkdir -p /Volumes/NAS_1/${USER_NAME}/openclaw/media/recordings
```

**Note:** Adjust paths based on your setup:
- Each user has their own data subdirectory (`~/openclaw/xin/` or `~/openclaw/zhuoyue/`)
- Google Drive path depends on your sync location (for cloud backup via rsync)
- NAS path depends on your mount point (audio files are moved here after transcription)
- The `~/openclaw/` folder is shared with the VM via VirtioFS
- For multi-user setup: use per-user script directories (e.g., `xin/`, `zhuoyue/`) with hardcoded paths

### 1.5 Configure Hotwords (Optional)

Hotwords are domain-specific terms that improve transcription accuracy for proper nouns, technical terms, and project-specific vocabulary. They are used only with VibeVoice-ASR (recordings > 10 minutes).

**Create the hotwords file:**

```bash
# Replace 'xin' with your username (or 'zhuoyue' for second user)
USER_NAME="xin"

# Copy the example file
cp scripts/knowledge-base/hotwords-example.txt ~/openclaw/${USER_NAME}/config/hotwords.txt

# Edit to add your terms (one per line)
nano ~/openclaw/${USER_NAME}/config/hotwords.txt
```

**Example hotwords file:**

```
OpenClaw
VibeVoice
MLX
Apple Silicon
Claude Sonnet
```

**Agent-driven updates:**

Before a meeting, ask your Telegram agent to update the hotwords:

```
"Update hotwords for my next meeting: Alice, Bob, ProjectX"
```

The agent writes to `/Volumes/My Shared Files/config/hotwords.txt` (VM path), which is the same file as `~/openclaw/config/hotwords.txt` (host path) via the shared folder. Changes take effect immediately on the next transcription.

**Path mapping:**

| Side | Path | Notes |
|------|------|-------|
| **Host Mac** | `~/openclaw/xin/config/hotwords.txt` | Read by `transcribe.sh` |
| **VM** | `/Volumes/My Shared Files/xin/config/hotwords.txt` | Written by agent |

Same file, bidirectional via VirtioFS.

**When are hotwords used?**

- ✅ VibeVoice-ASR (recordings > 10 minutes)
- ❌ Whisper-turbo (recordings < 10 minutes)
- If the file is missing or empty, transcription proceeds without context (backward compatible)

For more details, see [transcribe-flow.md](./transcribe-flow.md#hotwords-configuration).

### 1.6 Test the Transcription Pipeline

```bash
# Replace 'xin' with your username (or 'zhuoyue' for second user)
USER_NAME="xin"

# Create test recording (script auto-converts to MP3 for transcription)
say "Hello, this is a test of the transcription system." -o ~/openclaw/${USER_NAME}/media/inbound/test.aiff

# Run transcription (auto-converts aiff → mp3, then transcribes)
~/openclaw/scripts/knowledge-base/${USER_NAME}/transcribe.sh

# Check transcript output (local first, then synced to cloud)
ls ~/openclaw/${USER_NAME}/transcripts/
cat ~/openclaw/${USER_NAME}/transcripts/*test*.json

# Check transcript was synced to Google Drive
ls ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/${USER_NAME}/transcripts/

# Check audio was moved to NAS
ls /Volumes/NAS_1/${USER_NAME}/openclaw/media/recordings/
```

**Expected output:**
- JSON file with transcription, timestamps, and speaker labels in `~/openclaw/transcripts/`
- Same transcript synced to Google Drive
- Audio file moved to NAS at `/Volumes/NAS_1/Xin/openclaw/media/recordings/`

### 1.7 Auto-Transcribe with launchd

For single-user setup, copy the pre-configured plist:

```bash
# Copy the plist for your user (xin or zhuoyue)
cp scripts/knowledge-base/xin/com.user.transcribe-xin.plist ~/Library/LaunchAgents/

# IMPORTANT: Edit the file to update YOUR_USERNAME to your actual macOS username
nano ~/Library/LaunchAgents/com.user.transcribe-xin.plist

# Load the plist
launchctl load ~/Library/LaunchAgents/com.user.transcribe-xin.plist

# Test: drop a file in ~/openclaw/xin/media/inbound and check logs
tail -f /tmp/transcribe-xin.log
```

**For multi-user setup:** Load both plists:

```bash
# User 1 (xin)
cp scripts/knowledge-base/com.user.transcribe-xin.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.transcribe-xin.plist

# User 2 (zhuoyue)
cp scripts/knowledge-base/zhuoyue/com.user.transcribe-zhuoyue.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.transcribe-zhuoyue.plist

# Check both are running
launchctl list | grep transcribe
```

**Note:**
- Each plist watches a different directory (`~/openclaw/xin/media/inbound` vs `~/openclaw/zhuoyue/media/inbound`)
- Each plist points to the per-user script (no `USER_PROFILE` env var needed)
- Audio files are automatically moved to NAS and transcripts saved to Google Drive after successful transcription
- Logs are separated: `/tmp/transcribe-xin.log` and `/tmp/transcribe-zhuoyue.log`

---

## Part 2: Lume VM Setup

### 2.1 Create VM

```bash
# Create Ubuntu VM (lighter than macOS)
lume create memory-app --os ubuntu --cpu 4 --memory 8192 --disk 50G

# Or macOS VM (if you prefer):
# lume create memory-app --os macos --cpu 4 --memory 8192 --disk 50G
```

### 2.2 Start VM with Unified Shared Folder

**Important:** The Lume CLI `--shared-dir` flag only accepts **ONE** shared folder due to macOS Virtualization framework limitations.

**Solution:** Use `~/openclaw` as a single unified folder containing all subdirectories (media, workspace, transcripts).

**Setup:**

```bash
# Start VM with unified shared directory
lume run nix --shared-dir ~/openclaw
```

**Why this works:**
- VirtioFS shares the entire `~/openclaw/` folder tree
- VM sees all subdirectories at `/Volumes/My Shared Files/`
- No symlinks needed (symlinks outside shared dir don't work with VirtioFS)
- Host syncs workspace + transcripts to Google Drive after transcription

### 2.3 Verify Shared Folders

```bash
# SSH into VM
lume ssh nix

# Check mounts (should see the unified folder structure)
ls "/Volumes/My Shared Files/"
ls "/Volumes/My Shared Files/media/recordings"
ls "/Volumes/My Shared Files/transcripts"
ls "/Volumes/My Shared Files/workspace"
```

All subdirectories should be accessible from the VM via the shared mount point.

---

## Part 3: OpenClaw Setup (VM)

### 3.1 Install Prerequisites

```bash
# Update system (Ubuntu)
sudo apt update
sudo apt install -y curl git build-essential

# Install Node.js 22+
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs

# Install pnpm
npm install -g pnpm
```

### 3.2 Install OpenClaw

**Option A: From npm (stable)**
```bash
npm install -g openclaw@latest
```

**Option B: From source (development)**
```bash
cd ~
git clone https://github.com/openclaw/openclaw.git
cd openclaw
pnpm install
pnpm build
pnpm link --global
```

### 3.2a Understanding Onboarding and Persistence

**Important: Onboard once, run continuously**

OpenClaw is designed to be onboarded **once** and then run as a persistent background service:

1. **Onboard once:** The first time you run `openclaw onboard`, it saves all configuration and credentials to `~/.openclaw/`
2. **Configuration persists:** All settings are stored on disk and survive VM restarts
3. **Gateway runs continuously:** The gateway process should stay running in the background
4. **After restart:** Just restart the gateway process - no need to re-onboard

**Configuration storage (references):**
- Config file: `~/.openclaw/openclaw.json` ([src/config/paths.ts:93-104](../../src/config/paths.ts))
- Credentials: `~/.openclaw/credentials/oauth.json` ([src/config/paths.ts:211-227](../../src/config/paths.ts))
- Sessions: `~/.openclaw/sessions/` (default)

**What happens on VM restart:**
- ✅ Configuration persists (stored on disk)
- ✅ Credentials persist (stored on disk)
- ❌ Gateway process stops (needs manual restart)

**When you need to restart the gateway:**
```bash
# After VM reboot
nohup openclaw gateway run --bind loopback --port 18789 --force > /tmp/openclaw-gateway.log 2>&1 &

# Verify it's running
openclaw channels status --probe
ss -ltnp | grep 18789
tail -n 120 /tmp/openclaw-gateway.log
```

**When to onboard again:**
- Only if you delete `~/.openclaw/` directory
- Only if you rebuild/reinstall the VM from scratch
- Only if you want to change credentials or add new channels

For more details on gateway startup and configuration loading, see:
- Gateway startup: [src/cli/gateway-cli/run.ts:95,161](../../src/cli/gateway-cli/run.ts)
- Config persistence: [src/config/io.ts:480-537](../../src/config/io.ts)

### 3.3 Configure OpenClaw

```bash
# Initialize
openclaw config init

# Set Kimi 2.5
openclaw config set agents.defaults.model "moonshot/kimi-2.5"

# Set Moonshot API key
openclaw config set providers.moonshot.apiKey "sk-..."

# Enable memory search
openclaw config set agents.defaults.memorySearch.enabled true

# Set embedding provider (Ollama — free, local)
openclaw config set agents.defaults.memorySearch.provider "openai"
openclaw config set agents.defaults.memorySearch.remote.baseUrl "http://192.168.64.1:11434/v1"
openclaw config set agents.defaults.memorySearch.remote.apiKey "ollama"
openclaw config set agents.defaults.memorySearch.model "qwen3-embedding:0.6b"

# Disable batch embeddings (Ollama does not support OpenAI Batch API)
openclaw config set agents.defaults.memorySearch.remote.batch.enabled false
```

**Note:** Ollama runs on the host Mac, not inside the VM. For the VM to reach it:

1. **Start Ollama on all interfaces** (it defaults to `127.0.0.1` only):
   ```bash
   # On host Mac:
   OLLAMA_HOST=0.0.0.0 ollama serve
   ```
   To make this permanent, add `export OLLAMA_HOST=0.0.0.0` to your shell profile.

2. **`192.168.64.1`** is the host gateway IP from inside a Lume VM (Apple Virtualization NAT). Verify:
   ```bash
   # Inside the VM:
   ip route | grep default
   # expected: default via 192.168.64.1 ...
   ```

### 3.4 Configure Media Download Path

**Important**: The `tools.media.downloadPath` config does NOT currently exist in OpenClaw. Audio files always download to `~/.openclaw/media/inbound/` inside the VM. To use the local transcription pipeline, you need a workaround.

**Workaround: Symlink inbound folder to shared directory**

```bash
# Inside VM: symlink inbound to shared folder
mv ~/.openclaw/media/inbound ~/.openclaw/media/inbound.backup
ln -s "/Volumes/My Shared Files/media/recordings" ~/.openclaw/media/inbound

# Disable cloud transcription (use mlx-audio on host for 100% local processing)
openclaw config set tools.media.audio.enabled false
```

**See [telegram-audio-flow.md](./telegram-audio-flow.md) for detailed flow documentation and alternative workarounds.**

### 3.5 Configure Workspace

Point OpenClaw workspace to the shared folder:

```bash
# Symlink workspace to shared folder mount
ln -sf "/Volumes/My Shared Files/workspace" ~/.openclaw/workspace

# Verify
ls -la ~/.openclaw/workspace/
ls "/Volumes/My Shared Files/media/recordings"
ls "/Volumes/My Shared Files/transcripts"
```

### 3.6 Create Memory Files (on Host)

Create initial memory file on your **host Mac** in the shared workspace:

```bash
# On host Mac:
cat > ~/openclaw/workspace/MEMORY.md << 'EOF'
# Long-Term Memory

## About Me
- Name: [Your name]
- Role: [Your role]

## Preferences
- Coding style: [Preferences]
- Meeting schedule: [Schedule]

## Important Context
- [Key information]

## Active Projects
- [Project list]

## Decisions Log
<!-- Agent will append decisions here -->
EOF

# Create notes directory
mkdir -p ~/openclaw/workspace/notes
```

This file will automatically:
- Appear in the VM at `/Volumes/My Shared Files/workspace/MEMORY.md`
- Be synced to Google Drive after transcription runs
- Transcripts at `/Volumes/My Shared Files/transcripts/` are also searchable by the agent

### 3.7 Test Memory Search

```bash
# Index existing files
openclaw memory index

# Search
openclaw memory search "test"

# Status
openclaw memory status
```

---

## Part 4: Telegram Bot Setup

### 4.1 Create Telegram Bot

1. Open Telegram → search `@BotFather`
2. Send `/newbot`
3. Name: `[Your Name] Memory Bot`
4. Username: `your_memory_bot`
5. Copy the bot token (starts with numbers)

### 4.2 Get Your Telegram User ID

1. Message `@userinfobot` on Telegram
2. Copy your user ID (numbers only)

### 4.3 Configure Telegram in OpenClaw

```bash
# Set bot token
openclaw config set channels.telegram.token "YOUR_BOT_TOKEN"

# Set allowlist (your user ID)
openclaw config set channels.telegram.allowlist '["YOUR_USER_ID"]'

# Increase media size limit (for voice messages)
openclaw config set channels.telegram.mediaMaxMb 20

# Disable cloud transcription (use mlx-audio on host for 100% local processing)
openclaw config set tools.media.audio.enabled false

# Note: See section 3.4 for download path workaround (symlink required)
```

**What this does:**
- Telegram voice messages → downloaded to `~/.openclaw/media/inbound/` (in VM)
- If you created the symlink in section 3.4, files appear in the shared folder immediately
- launchd on host watches for new files → triggers mlx-audio transcription
- Transcripts written to `~/openclaw/transcripts/` → visible to VM at `/Volumes/My Shared Files/transcripts/`
- After transcription, rsync syncs workspace + transcripts to Google Drive
- Audio files automatically moved to NAS after successful transcription

**See [telegram-audio-flow.md](./telegram-audio-flow.md) for detailed technical flow documentation.**

### 4.5 Start Gateway

**Important:** The gateway should run continuously as a background service. See [3.2a Understanding Onboarding and Persistence](#32a-understanding-onboarding-and-persistence) for details.

```bash
# Foreground (for testing)
openclaw gateway run

# Background (for production - keeps running until VM restart)
nohup openclaw gateway run --bind loopback --port 18789 --force > /tmp/openclaw-gateway.log 2>&1 &
```

**After VM restart:** You'll need to run the background command again. The configuration persists automatically, so no need to re-onboard or reconfigure.

### 4.6 Test Your Bot

1. Open Telegram → search for your bot
2. Send `/start`
3. Send "Hello!"
4. Bot should respond

Try voice:
- Hold mic button → "Testing voice transcription" → release
- Bot should reply with transcribed text

---

## Part 5: Async Transcription Pipeline

### 5.1 When to Use Async Pipeline

Use the async pipeline for **long recordings** that take hours to transcribe:

- Multi-hour meetings
- Conference recordings
- Long interviews
- Podcasts

For short voice messages (< 5 minutes), the standard sync flow works fine.

### 5.2 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      VM (OpenClaw)                          │
│  Telegram → /Volumes/My Shared Files/media/recordings/ ─────┼──┐
│                                                             │  │
│  [transcript-watcher] ← /Volumes/My Shared Files/transcripts/ ←──────┼──┼──┐
│       ↓                                                     │  │  │
│  openclaw agent --message (AI processes transcript)         │  │  │
│       ↓                                                     │  │  │
│  Summarizes, extracts actions, updates memory               │  │  │
└─────────────────────────────────────────────────────────────┘  │  │
                                                                 │  │
┌────────────────────────────────────────────────────────────────┼──┼─┐
│                      HOST (macOS)                              │  │ │
│  ~/openclaw/media/recordings/ ←────────────────────────────────┘  │ │
│       ↓                                                           │ │
│  mlx_audio (VibeVoice-ASR) watches, transcribes (launchd)        │ │
│       ↓                                                           │ │
│  ~/openclaw/transcripts/ (.json output) ──────────────────────────┘ │
│       ↓                                                             │
│  rsync → Google Drive (workspace + transcripts)                    │
│  mv → NAS (audio archival)                                         │
└─────────────────────────────────────────────────────────────────────┘
```

**Flow:**

1. **Telegram → VM:** Audio downloaded directly to shared folder `/Volumes/My Shared Files/media/recordings/`
2. **mlx_audio (Host):** launchd watches `~/openclaw/media/recordings/`, transcribes with VibeVoice-ASR, saves to `~/openclaw/transcripts/`
3. **Sync (Host):** After transcription, rsync syncs workspace + transcripts to Google Drive, moves audio to NAS
4. **transcript-watcher (VM):** Picks up transcripts from `/Volumes/My Shared Files/transcripts/`, triggers AI processing via `openclaw agent --message` (summarizes, extracts action items, updates memory)

### 5.3 Setup: Disable Built-in Transcription

Since we're using mlx_audio on the host for transcription, disable the built-in cloud transcription:

```bash
# Inside VM
openclaw config set tools.media.audio.enabled false
```

This ensures audio files are downloaded but not transcribed by OpenClaw (we handle transcription on the host).

### 5.4 Setup: Get Your Telegram Chat ID

To send transcripts back to Telegram, you need your chat ID:

```bash
# Option 1: Send a message to @userinfobot on Telegram
# It will reply with your user ID (chat ID)

# Option 2: Get it from OpenClaw gateway logs
# Send a message to your bot, then check:
tail -f /tmp/openclaw-gateway.log | grep "chat"
```

### 5.4a Voice Transcript Session Routing

Voice transcripts are routed based on duration:

- **Short recordings (< 10 min):** Processed in the **same session** as your interactive Telegram messages. This gives the agent full conversational context — you can say something in a voice message and reference it in text (and vice versa).
- **Long recordings (≥ 10 min):** Processed by a **separate agent** (`transcript-processor`) to avoid blocking interactive messages for hours. After processing, a brief context summary is relayed to your main session so the agent knows what was discussed.

The Gateway serializes agent runs per session, so short transcripts don't cause lock contention. The 10-minute threshold balances context sharing with responsiveness.

**Create the transcript processor agent** (needed for long recordings):

```bash
# Inside VM - create agent that shares the main workspace
openclaw agents add transcript-processor --workspace ~/.openclaw/workspace
```

> **Customization:** Override the threshold and agent ID via environment variables:
> ```bash
> DURATION_THRESHOLD=300 AGENT_ID=custom-agent TELEGRAM_CHAT_ID=YOUR_CHAT_ID ./transcript-watcher.sh
> ```

### 5.5 Running the Watchers

**Terminal 1: Start Transcript Watcher - Inside VM**

**Important:** This watcher uses `openclaw agent --message` to trigger **AI processing** of transcripts. It adapts based on transcript metadata (duration, speakers, word count) to intelligently handle voice memos (brief storage) vs. meetings (full summary + action items). Requires `agents.defaults.memorySearch.experimental.sessionMemory: true` for automatic indexing.

```bash
# SSH into VM
lume ssh nix

# Enable session memory for automatic indexing (required)
openclaw config set agents.defaults.memorySearch.experimental.sessionMemory true

# Copy the watcher script (if not already done)
# (Run this on host first: scp scripts/knowledge-base/transcript-watcher.sh nix:~/)
```

**Running with tmux (recommended for headless VMs)**

LaunchAgents don't work in headless macOS VMs accessed via SSH (they require a GUI/Aqua session). Use tmux instead:

```bash
# SSH into VM
lume ssh nix

# Start tmux session (persists across SSH disconnects)
tmux new-session -d -s transcript-watcher \
  "TELEGRAM_CHAT_ID=YOUR_CHAT_ID_HERE /Volumes/My\ Shared\ Files/scripts/transcript-watcher.sh"

# Attach to check logs
tmux attach -t transcript-watcher

# Detach: Ctrl+B, D
```

**To stop the watcher:**

```bash
tmux kill-session -t transcript-watcher
```

### 5.6 Testing the Pipeline

1. **Send a voice message** to your Telegram bot (or upload audio file)
2. **Check audio lands in shared folder:** `ls ~/openclaw/media/recordings/` (on host)
3. **Check host transcription:** `tail -f /tmp/transcribe.log` (if using launchd)
4. **Check transcript appears:** `ls ~/openclaw/transcripts/` (on host)
5. **Check transcript-watcher:** Should see "New transcript: filename.txt" and send confirmation (in VM)
6. **Check Telegram:** Should receive the transcribed text as a message from your bot

### 5.7 Troubleshooting Async Pipeline

**Audio not appearing in shared folder:**
- Check symlink exists: `ls -la ~/.openclaw/media/inbound` (should point to shared folder)
- Check VM can see shared folder: `ls /Volumes/My\ Shared\ Files/media/recordings/` (in VM)
- Check host folder: `ls ~/openclaw/media/recordings/` (on host)
- Verify VM is running with shared dir: `lume run nix --shared-dir ~/openclaw`
- If symlink missing, recreate per section 3.4

**Transcription not happening:**
- Check host launchd: `launchctl list | grep transcribe`
- Check mlx-audio: `python -c "import mlx_audio"`
- Check transcription logs: `tail -f /tmp/transcribe.log`
- Check recordings folder: `ls ~/openclaw/media/recordings/`

**Transcripts not being processed:**
- Check transcript-watcher is running: `tmux ls` and look for `transcript-watcher` session (in VM)
- Check logs: `tmux attach -t transcript-watcher` to view live output (in VM)
- Check session memory enabled: `openclaw config get agents.defaults.memorySearch.experimental.sessionMemory` (in VM)
- Check VM can see transcripts: `ls /Volumes/My\ Shared\ Files/transcripts/` (in VM)
- Check host transcripts: `ls ~/openclaw/transcripts/` (on host)
- Test manual processing: `openclaw agent --message "Summarize: Test transcript" --thinking medium` (in VM)

### 5.8 Verification Checklist

After implementing the async pipeline, verify everything is working:

- [ ] VM starts with shared folder: `lume run nix --shared-dir ~/openclaw`
- [ ] Shared folders visible in VM: `ls "/Volumes/My Shared Files/"`
- [ ] Host transcription working: check `/tmp/transcribe.log`
- [ ] Session memory enabled: `openclaw config set agents.defaults.memorySearch.experimental.sessionMemory true`
- [ ] transcript-watcher running in VM: `tmux ls` shows `transcript-watcher` session
- [ ] Send voice message to Telegram bot
- [ ] Verify audio lands in `~/openclaw/media/recordings/` (host)
- [ ] Verify mlx_audio transcribes to `~/openclaw/transcripts/` (host)
- [ ] Verify transcripts synced to Google Drive
- [ ] Verify audio moved to NAS
- [ ] Verify transcript processed by AI (check tmux session output in VM)

**Expected timeline for long recordings:**
- Voice message sent → appears in shared folder immediately (< 1 second)
- Host transcription → varies by length (e.g., 2-hour meeting ≈ 30-60 minutes)
- After transcription → rsync to Google Drive, move to NAS (< 10 seconds)
- transcript-watcher sends → immediately after transcript appears (< 1 second)


## Part 6: Backup and Sync Strategy

### What Gets Backed Up

| Data | Location | Backup Method | Why |
|------|----------|---------------|-----|
| **Markdown files** | Google Drive | Cloud sync | Your actual knowledge |
| **Voice messages** | ~/openclaw/media/recordings | Immediate to NAS after transcription | Original audio files |
| **Transcripts** | Google Drive | Cloud sync | Searchable text for LLM |
| **Databases** | VM only | Not backed up | Rebuildable from markdown |
| **Config/credentials** | VM only | Manual backup | Sensitive, manual only |

### How Sync Works

```
┌───────────────────────────────────────────────────────────────────────┐
│ Unified Folder Flow:                                                  │
│                                                                       │
│ 1. Send voice memo to Telegram                                       │
│    ↓                                                                  │
│ 2. OpenClaw downloads to /Volumes/My Shared Files/media/recordings   │
│    (backed by ~/openclaw/media/recordings on host)                   │
│    ↓                                                                  │
│ 3. launchd triggers transcribe.sh on host                            │
│    ↓                                                                  │
│ 4. mlx-audio transcribes locally (Metal GPU, 100% local)             │
│    ↓                                                                  │
│ 5. Save transcript JSON to ~/openclaw/transcripts/                   │
│    ↓                                                                  │
│ 6. rsync workspace + transcripts to Google Drive                     │
│    ↓                                                                  │
│ 7. Move audio to NAS (/Volumes/NAS_1/.../recordings/)                │
│    ↓                                                                  │
│ 8. VM sees transcript at /Volumes/My Shared Files/transcripts        │
│    ↓                                                                  │
│ 9. Agent processes transcript, writes notes to workspace             │
│    (automatically synced to Google Drive on next transcription)      │
└───────────────────────────────────────────────────────────────────────┘
```

### Manual Backups (Config Only)

Databases rebuild automatically from markdown, but config/credentials should be backed up manually:

```bash
# Inside VM (do this occasionally)
tar -czf /tmp/openclaw-config-backup.tar.gz ~/.openclaw/config.yaml ~/.openclaw/credentials/

# Copy to host
# (from host Mac)
lume ssh memory-app -- cat /tmp/openclaw-config-backup.tar.gz > ~/openclaw-config-backup.tar.gz
```

### Disaster Recovery

If VM dies or databases corrupt:

1. **Your data is safe** - markdown and transcripts in Google Drive, audio on NAS
2. **Recreate VM** following Part 2
3. **Reinstall OpenClaw** following Part 3
4. **Restore config** from backup (or reconfigure)
5. **Reindex memory**: `openclaw memory index --force`

Done. All your knowledge is back.

### Multi-Device Access

Since markdown lives in Google Drive:

- **Read on phone** - Google Drive app
- **Edit on laptop** - any text editor + Google Drive sync
- **Query via Telegram** - works from anywhere


## Useful Commands

### Memory Management

```bash
# Index status
openclaw memory status

# Re-index
openclaw memory index --force

# Search
openclaw memory search "keyword"
```

### Gateway

```bash
# Channel status
openclaw channels status

# Logs
tail -f /tmp/openclaw.log
```

### VM (from host)

```bash
# Start
lume start memory-app

# Stop
lume stop memory-app

# SSH
lume ssh memory-app

# Restart
lume restart memory-app
```

---

## Troubleshooting

### Browser Setup

After the gateway starts, launch the browser process:

```bash
# Inside VM
openclaw browser start --profile=chrome
```

---

## Resources

- **OpenClaw Docs**: https://docs.openclaw.ai/
- **Telegram Bot API**: https://core.telegram.org/bots/api
- **mlx-audio**: https://github.com/Blaizzy/mlx-audio
- **VibeVoice-ASR**: https://huggingface.co/mlx-community/VibeVoice-ASR-bf16
- **Lume VM**: https://github.com/lume-vm/lume

---

## Support

- GitHub Issues: https://github.com/openclaw/openclaw/issues
- Community: [Join Discord/Slack]
- Docs: https://docs.openclaw.ai/

---

## License

This guide is part of the OpenClaw project. See LICENSE for details.
