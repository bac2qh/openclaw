# Personal Knowledge Base with OpenClaw

Build a voice-powered memory system using OpenClaw, mlx-audio (VibeVoice), Lume VM, and Claude Sonnet 4.

## Quick Start

**What you'll build:**
- Voice memos via Telegram → auto-transcribed → searchable memory
- Meeting recordings → transcribed with speaker labels → indexed
- Natural language queries: "What did we decide about the API?"
- Reminders: "Remind me tomorrow at 9am about the standup"

**Total setup time:** ~30 minutes
**Monthly cost:** ~$6 (Claude API only - transcription is 100% local)

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
│  │ │ └── Claude Sonnet 4  │ │                                           │
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
5. [Async Transcription Pipeline](#part-5-async-transcription-pipeline-2-watcher-setup)
6. [Daily Workflow](#part-6-daily-workflow)
7. [Cost Breakdown](#part-7-cost-summary)
8. [Troubleshooting](#troubleshooting)

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

Copy the transcription script:

```bash
mkdir -p ~/openclaw/scripts
cp scripts/knowledge-base/transcribe.sh ~/openclaw/scripts/
chmod +x ~/openclaw/scripts/transcribe.sh
```

### 1.4 Create Directories

```bash
# Unified shared folder structure
mkdir -p ~/openclaw/media/recordings
mkdir -p ~/openclaw/workspace
mkdir -p ~/openclaw/transcripts
mkdir -p ~/openclaw/scripts

# Google Drive destinations (cloud backup)
mkdir -p ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/workspace
mkdir -p ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/transcripts

# NAS (archival - audio only)
mkdir -p /Volumes/NAS_1/Xin/openclaw/media/recordings
```

**Note:** Adjust paths based on your setup:
- Google Drive path depends on your sync location (for cloud backup via rsync)
- NAS path depends on your mount point (audio files are moved here after transcription)
- The `~/openclaw/` folder is shared with the VM via VirtioFS

### 1.5 Test the Transcription Pipeline

```bash
# Create test recording (script auto-converts to MP3 for transcription)
say "Hello, this is a test of the transcription system." -o ~/openclaw/media/recordings/test.aiff

# Run transcription (auto-converts aiff → mp3, then transcribes)
~/openclaw/scripts/transcribe.sh

# Check transcript output (local first, then synced to cloud)
ls ~/openclaw/transcripts/
cat ~/openclaw/transcripts/*test*.json

# Check transcript was synced to Google Drive
ls ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/transcripts/

# Check audio was moved to NAS
ls /Volumes/NAS_1/Xin/openclaw/media/recordings/
```

**Expected output:**
- JSON file with transcription, timestamps, and speaker labels in `~/openclaw/transcripts/`
- Same transcript synced to Google Drive
- Audio file moved to NAS at `/Volumes/NAS_1/Xin/openclaw/media/recordings/`

### 1.6 Auto-Transcribe with launchd

Create `~/Library/LaunchAgents/com.user.transcribe.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.transcribe</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/YOUR_USERNAME/openclaw/scripts/transcribe.sh</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/Users/YOUR_USERNAME/openclaw/media/recordings</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/transcribe.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/transcribe.err</string>
</dict>
</plist>
```

Replace `YOUR_USERNAME`, then load:

```bash
launchctl load ~/Library/LaunchAgents/com.user.transcribe.plist

# Test: drop a file in ~/openclaw/media/recordings and check logs
tail -f /tmp/transcribe.log
```

**Note:** Audio files are automatically moved to NAS and transcripts saved to Google Drive after successful transcription.

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

# Set Claude Sonnet 4
openclaw config set agents.defaults.model "claude-sonnet-4-20250514"

# Set Anthropic API key
openclaw config set providers.anthropic.apiKey "sk-ant-..."

# Enable memory search
openclaw config set agents.defaults.memorySearch.enabled true

# Set embedding provider (OpenAI)
openclaw config set agents.defaults.memorySearch.provider "openai"
openclaw config set providers.openai.apiKey "sk-..."
```

### 3.4 Configure Media Download Path

Point OpenClaw to save Telegram voice messages to the shared recordings folder:

```bash
# Set download path (temporary storage - moved to NAS after transcription)
openclaw config set tools.media.downloadPath "/Volumes/My Shared Files/media/recordings"

# Disable cloud transcription (use mlx-audio on host for 100% local processing)
openclaw config set tools.media.audio.enabled false
```

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

# Set media download path to shared recordings folder
openclaw config set tools.media.downloadPath "/Volumes/My Shared Files/media/recordings"

# Disable cloud transcription (use mlx-audio on host for 100% local processing)
openclaw config set tools.media.audio.enabled false
```

**What this does:**
- Telegram voice messages → downloaded to `/Volumes/My Shared Files/media/recordings` (in VM)
- This folder is backed by `~/openclaw/media/recordings/` on host via VirtioFS
- launchd watches for new files → triggers mlx-audio transcription on host
- Transcripts written to `~/openclaw/transcripts/` → visible to VM at `/Volumes/My Shared Files/transcripts/`
- After transcription, rsync syncs workspace + transcripts to Google Drive
- Audio files automatically moved to NAS after successful transcription

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

## Part 5: Async Transcription Pipeline (2-Watcher Setup)

### 5.1 When to Use Async Pipeline

Use the async pipeline for **long recordings** that take hours to transcribe:

- Multi-hour meetings
- Conference recordings
- Long interviews
- Podcasts

For short voice messages (< 5 minutes), the standard sync flow works fine.

### 5.2 Architecture: 2-Watcher Async Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                      VM (OpenClaw)                          │
│  Telegram → /Volumes/My Shared Files/media/recordings/ ─────┼──┐
│                                                             │  │
│  [Watcher 2] ← /Volumes/My Shared Files/transcripts/ ←──────┼──┼──┐
│       ↓                                                     │  │  │
│  openclaw message send → Telegram                           │  │  │
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
4. **Watcher 2 (VM):** Picks up transcripts from `/Volumes/My Shared Files/transcripts/`, sends via `openclaw message send` to Telegram

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

### 5.5 Setup: Install fswatch

Both watcher scripts use `fswatch` to monitor directories:

```bash
# On host Mac
brew install fswatch

# Inside VM (if running watchers there)
sudo apt install fswatch  # Ubuntu/Debian
```

### 5.6 Running the Watchers

**Note:** With the unified folder approach, Watcher 1 (audio copier) is optional - audio already lands in the shared folder. You only need Watcher 2 to send transcripts back to Telegram.

**Optional: Monitor Audio (Inside VM)**

```bash
# SSH into VM
lume ssh nix

# Copy the watcher script (if not already done)
# (Run this on host first: scp scripts/knowledge-base/audio-watcher.sh nix:~/)

# Run the audio monitor (optional - just for logging)
chmod +x ~/audio-watcher.sh
~/audio-watcher.sh
```

**Terminal 1: Start Watcher 2 (Transcript Sender) - Inside VM**

```bash
# SSH into VM
lume ssh nix

# Set your Telegram chat ID
export TELEGRAM_CHAT_ID="YOUR_CHAT_ID_HERE"

# Copy the watcher script (if not already done)
# (Run this on host first: scp scripts/knowledge-base/transcript-watcher.sh nix:~/)

# Run the transcript watcher
chmod +x ~/transcript-watcher.sh
~/transcript-watcher.sh
```

**Pro Tip: Use tmux for persistent sessions**

```bash
# Inside VM
tmux new -s watchers

# Window 1: Transcript watcher (required)
export TELEGRAM_CHAT_ID="YOUR_CHAT_ID_HERE"
~/transcript-watcher.sh

# Optional: Create new window for audio monitor (Ctrl+B, C)
# ~/audio-watcher.sh

# Detach: Ctrl+B, D
# Reattach: tmux attach -t watchers
```

### 5.7 Testing the Pipeline

1. **Send a voice message** to your Telegram bot (or upload audio file)
2. **Check audio lands in shared folder:** `ls ~/openclaw/media/recordings/` (on host)
3. **Check host transcription:** `tail -f /tmp/transcribe.log` (if using launchd)
4. **Check transcript appears:** `ls ~/openclaw/transcripts/` (on host)
5. **Check Watcher 2:** Should see "New transcript: filename.txt" and send confirmation (in VM)
6. **Check Telegram:** Should receive the transcribed text as a message from your bot

### 5.8 Troubleshooting Async Pipeline

**Audio not appearing in shared folder:**
- Check OpenClaw download path: `openclaw config get tools.media.downloadPath` (should be `/Volumes/My Shared Files/media/recordings`)
- Check VM can see shared folder: `ls /Volumes/My\ Shared\ Files/media/recordings/` (in VM)
- Check host folder: `ls ~/openclaw/media/recordings/` (on host)
- Verify VM is running with shared dir: `lume run nix --shared-dir ~/openclaw`

**Transcription not happening:**
- Check host launchd: `launchctl list | grep transcribe`
- Check mlx-audio: `python -c "import mlx_audio"`
- Check transcription logs: `tail -f /tmp/transcribe.log`
- Check recordings folder: `ls ~/openclaw/media/recordings/`

**Transcripts not being sent:**
- Check Watcher 2 is running: `ps aux | grep transcript-watcher` (in VM)
- Check Telegram chat ID is set: `echo $TELEGRAM_CHAT_ID` (in VM)
- Check VM can see transcripts: `ls /Volumes/My\ Shared\ Files/transcripts/` (in VM)
- Check host transcripts: `ls ~/openclaw/transcripts/` (on host)
- Test manual send: `openclaw message send --channel telegram --target "$TELEGRAM_CHAT_ID" --message "test"` (in VM)

### 5.9 Verification Checklist

After implementing the async pipeline, verify everything is working:

- [ ] VM starts with shared folder: `lume run nix --shared-dir ~/openclaw`
- [ ] Shared folders visible in VM: `ls "/Volumes/My Shared Files/"`
- [ ] Host transcription working: check `/tmp/transcribe.log`
- [ ] Watcher 2 running in VM (transcript sender)
- [ ] Send voice message to Telegram bot
- [ ] Verify audio lands in `~/openclaw/media/recordings/` (host)
- [ ] Verify mlx_audio transcribes to `~/openclaw/transcripts/` (host)
- [ ] Verify transcripts synced to Google Drive
- [ ] Verify audio moved to NAS
- [ ] Verify transcript sent back to Telegram

**Expected timeline for long recordings:**
- Voice message sent → appears in shared folder immediately (< 1 second)
- Host transcription → varies by length (e.g., 2-hour meeting ≈ 30-60 minutes)
- After transcription → rsync to Google Drive, move to NAS (< 10 seconds)
- Watcher 2 sends → immediately after transcript appears (< 1 second)

---

## Part 6: Daily Workflow

### 6.1 Quick Voice Memos

**Via Telegram voice message:**
1. Open bot → hold mic → speak → release
2. Bot transcribes and responds

Examples:
```
"Remember that John prefers morning meetings"
"Note: API deadline is March 15th"
"Todo: review security proposal tomorrow"
```

### 6.2 Short Meetings (< 1 hour)

**Option A: Record in Telegram**
- Long-press mic for voice message
- Speak during meeting
- Release when done
- Bot transcribes automatically

**Option B: Upload audio file**
1. Record with Voice Memos/QuickTime
2. Telegram → bot → attachment → Audio
3. Add caption: "Meeting with design team"
4. Bot transcribes

### 6.3 Long Meetings (> 1 hour)

**Option A: Use async 2-watcher pipeline (recommended for multi-hour recordings)**

1. Send audio file to Telegram bot (or record directly in OpenClaw media folder)
2. Watcher 1 copies to shared folder
3. mlx_audio transcribes on host (may take hours)
4. Watcher 2 sends transcript back to Telegram when done
5. Bot automatically indexes and makes searchable

**Option B: Use host transcription directly (for recordings not from Telegram)**

```bash
# On host Mac:
# 1. Record to ~/openclaw/media/recordings/meeting-2024-01-15.m4a
# 2. Transcription runs automatically (or manually):
~/openclaw/scripts/transcribe.sh

# Transcript appears in ~/openclaw/transcripts/
# Synced to Google Drive via rsync
# Audio moved to NAS at /Volumes/NAS_1/Xin/openclaw/media/recordings/
# VM sees transcript at /Volumes/My Shared Files/transcripts/
```

Then tell bot:
```
"Index the meeting from January 15th and summarize"
```

**Archival:**
- Audio files: moved to NAS immediately after transcription
- Transcripts: saved to Google Drive (synced to cloud, accessible from any device)
- NAS path: `/Volumes/NAS_1/Xin/openclaw/media/recordings/`

### 6.4 Query Your Memory

Send to bot (text or voice):
```
"What did we discuss yesterday?"
"What are John's preferences?"
"Summarize this week's decisions"
"Find tasks for the frontend"
"What was decided about the API?"
```

### 6.5 Store Important Info

```
"Remember: AWS account ID is 123456789"
"Store: production needs 2 approvers"
"Important: Sarah is on vacation Feb 1-15"
```

### 6.6 Daily Review

End of day:
```
"Summarize everything I noted today and list action items"
```

---

## Part 7: Reminders

OpenClaw has built-in cron for reminders.

### Examples

Send to bot:
```
"Remind me in 20 minutes to check the build"
"Remind me tomorrow at 9am about standup"
"Daily reminder at 6pm to write journal"
"Every Monday at 10am remind me to review metrics"
```

### Manage Reminders

```
"List my reminders"
"Cancel the standup reminder"
"Show scheduled jobs"
```

Or via CLI:
```bash
openclaw cron list
openclaw cron remove <job-id>
```

---

## Part 8: Backup and Sync Strategy

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

---

## Part 9: Cost Summary

### Unified Local Transcription Flow

| Component | Monthly Cost |
|-----------|--------------|
| Claude Sonnet 4 (~1.2M tokens) | ~$6 |
| OpenAI Embeddings (~100K tokens) | ~$0.10 |
| mlx-audio (local transcription) | **FREE** |
| **Total** | **~$6/month** |

### Usage Estimates

- Voice memos: 20/day × 1 min = 600 min/month
- Meetings: 3/week × 1 hour = 720 min/month
- Long recordings: 2/month × 2 hours = 240 min/month
- **All transcription: 100% local via mlx-audio (FREE)**
- LLM queries: ~40/day × ~30K tokens = 1.2M tokens/month

### Why This Setup?

**Benefits:**
- ✅ **10x cheaper** than cloud transcription ($6 vs $60+/month)
- ✅ **100% privacy** for voice/audio (never leaves your Mac)
- ✅ **Built-in speaker diarization** (VibeVoice-ASR)
- ✅ **Fast** (Metal GPU acceleration on M1/M2/M3)
- ✅ **Simple** (single unified flow)
- ✅ **Immediate NAS archival** (audio moved after transcription)
- ✅ **Fast LLM access** (transcripts stay local)

**Requirements:**
- Apple Silicon Mac (M1/M2/M3) for mlx-audio
- NAS for archival (audio files moved immediately after transcription)

---

## Part 10: Getting Claude API Access

### Why API (not subscription)?

| Factor | API | Claude Pro |
|--------|-----|------------|
| **For OpenClaw** | ✅ Required | ❌ Won't work |
| **Pay-as-you-go** | ✅ ~$6/mo | ❌ $20/mo flat |
| **Programmatic** | ✅ Yes | ❌ Web only |

**You need the API.** Subscription is for web chat only.

### Setup

1. Create account: https://console.anthropic.com/
2. Billing → Add payment method
3. API Keys → Create Key
4. Copy key (starts with `sk-ant-`)
5. Configure: `openclaw config set providers.anthropic.apiKey "sk-ant-..."`

### Set Spending Limit (Optional)

Console → Settings → Limits → Monthly spend: $20

### Test

```bash
openclaw agent --message "Hello, confirm you are Sonnet 4"
```

---

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

### mlx-audio Issues

**Model not downloading:**
```bash
# Models auto-download from Hugging Face on first use
# If issues, try explicit download:
pip install huggingface_hub
huggingface-cli download mlx-community/VibeVoice-ASR-bf16
```

**Slow transcription:**
- Ensure you're on Apple Silicon (M1/M2/M3)
- Check Activity Monitor → GPU usage
- Increase `--max-tokens` parameter (default 8192)

**ImportError or pip issues:**
```bash
# Use a virtual environment
python3 -m venv ~/mlx-env
source ~/mlx-env/bin/activate
pip install mlx-audio
```

**Hallucination / repetitive output:**
- VibeVoice is generally more robust than Whisper
- Try adjusting `--temperature` (use 0.0 for deterministic output)
- Check audio quality (16kHz recommended)

### VM Issues

**Shared folder not visible:**
```bash
# Verify VM is running with correct shared dir
lume run nix --shared-dir ~/openclaw

# Check mounts inside VM
lume ssh nix
ls /Volumes/My\ Shared\ Files/
ls /Volumes/My\ Shared\ Files/media/recordings
ls /Volumes/My\ Shared\ Files/transcripts
ls /Volumes/My\ Shared\ Files/workspace
```

### Memory Not Indexing

```bash
# Force reindex
openclaw memory index --force

# Check status
openclaw memory status --deep

# Verify paths
ls ~/.openclaw/workspace/
ls /Volumes/My\ Shared\ Files/media/recordings
ls /Volumes/My\ Shared\ Files/transcripts
```

### Audio Files Not Transcribing

**Check launchd is running:**
```bash
# Check if loaded
launchctl list | grep transcribe

# Check logs
tail -f /tmp/transcribe.log
tail -f /tmp/transcribe.err

# Test manually
~/openclaw/scripts/transcribe.sh
```

**Check file permissions:**
```bash
ls -la ~/openclaw/media/recordings/
ls -la ~/openclaw/transcripts/
ls -la ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/transcripts/
```

### Audio Files Not Moving to NAS

**Check NAS mount:**
```bash
# Verify NAS is mounted
ls /Volumes/NAS_1/Xin/openclaw/media/recordings

# Check transcription logs
tail -f /tmp/transcribe.log

# Files should be moved immediately after transcription
# If NAS not mounted, files remain in ~/openclaw/media/recordings/
```

### Telegram Bot Not Responding

```bash
# Check gateway
ps aux | grep openclaw

# Check logs
tail -f /tmp/openclaw.log

# Verify config
openclaw config get channels.telegram

# Test connection
openclaw channels status --probe
```

### Voice Transcription Failing

**Check mlx-audio:**
```bash
# Test mlx-audio installation
python -c "import mlx_audio"

# Check model download
ls ~/.cache/huggingface/hub/ | grep VibeVoice

# Test transcription manually
say "Test" -o /tmp/test.aiff
ffmpeg -y -i /tmp/test.aiff /tmp/test.mp3 2>/dev/null
python -m mlx_audio.stt.generate \
    --model mlx-community/VibeVoice-ASR-bf16 \
    --audio /tmp/test.mp3 \
    --format json
```

**File too large:**
```bash
# Increase Telegram limit
openclaw config set channels.telegram.mediaMaxMb 50

# All files transcribed locally (no size limits on host)
```

---

## Next Steps

### 1. Add More Memory Sources

```bash
# Email archives
ln -s ~/mail-archive ~/.openclaw/workspace/mail

# Documents
ln -s ~/Documents/work ~/.openclaw/workspace/docs

# Code notes
ln -s ~/projects/notes ~/.openclaw/workspace/code-notes
```

### 2. Customize Agent Personality

Create `~/.openclaw/workspace/AGENT.md`:

```markdown
# Agent Instructions

You are my personal knowledge assistant. Your role is to:
1. Help me remember important context
2. Summarize meetings and decisions
3. Remind me of action items
4. Answer questions about past conversations

Communication style:
- Be concise and direct
- Use bullet points
- Highlight action items
- Include relevant timestamps/speakers
```

### 3. Advanced: Multi-Agent Setup

Run specialized agents for different contexts:

```yaml
# ~/.openclaw/config.yaml
agents:
  work:
    personality: "Professional assistant for work context"
    memorySearch:
      paths: ["/Volumes/My Shared Files/transcripts/work"]

  personal:
    personality: "Casual assistant for personal notes"
    memorySearch:
      paths: ["/Volumes/My Shared Files/transcripts/personal"]
```

### 4. Backup Strategy

```bash
# Backup script
#!/bin/bash
BACKUP_DIR=~/backups/openclaw-$(date +%Y-%m-%d)
mkdir -p "$BACKUP_DIR"

# Backup config only (transcripts and workspace already in Google Drive, audio on NAS)
cp -r ~/.openclaw "$BACKUP_DIR/"

# Compress
tar -czf "$BACKUP_DIR.tar.gz" "$BACKUP_DIR"
rm -rf "$BACKUP_DIR"
```

---

## FAQ

**Q: Can I use this without Lume VM?**
A: Yes, install OpenClaw directly on your Mac. Skip Part 2 and run everything on the host.

**Q: Can I use other messaging apps?**
A: Yes, OpenClaw supports Discord, Slack, Signal, WhatsApp, and more. See `openclaw channels status`.

**Q: How private is this?**
A: Voice transcription and LLM queries go to cloud APIs. For maximum privacy, use mlx-audio + local LLM (Ollama). mlx-audio runs 100% locally on your M1/M2/M3 Mac.

**Q: Can I run this on Linux?**
A: Yes, the VM setup works the same. For host transcription on Linux (or Intel Mac), use whisper.cpp or OpenAI Whisper instead of mlx-audio.

**Q: What if I want speaker names (not SPEAKER_00)?**
A: pyannote doesn't do speaker identification (who is who), only diarization (how many speakers). For names, use a service like AssemblyAI or manually label.

**Q: Can I search across all memories at once?**
A: Yes, that's the default. OpenClaw indexes everything under `~/.openclaw/workspace/` and `/Volumes/My Shared Files/transcripts/`.

---

## Resources

- **OpenClaw Docs**: https://docs.openclaw.ai/
- **Telegram Bot API**: https://core.telegram.org/bots/api
- **mlx-audio**: https://github.com/Blaizzy/mlx-audio
- **VibeVoice-ASR**: https://huggingface.co/mlx-community/VibeVoice-ASR-bf16
- **Lume VM**: https://github.com/lume-vm/lume
- **Claude API**: https://console.anthropic.com/

---

## Support

- GitHub Issues: https://github.com/openclaw/openclaw/issues
- Community: [Join Discord/Slack]
- Docs: https://docs.openclaw.ai/

---

## License

This guide is part of the OpenClaw project. See LICENSE for details.
