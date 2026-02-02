# Personal Knowledge Base with OpenClaw

Build a voice-powered memory system using OpenClaw, mlx-audio (VibeVoice), Lume VM, and Claude Sonnet 4.

## Quick Start

**What you'll build:**
- Voice memos via Telegram → auto-transcribed → searchable memory
- Meeting recordings → transcribed with speaker labels → indexed
- Natural language queries: "What did we decide about the API?"
- Reminders: "Remind me tomorrow at 9am about the standup"

**Total setup time:** ~30 minutes
**Monthly cost:** ~$16 (Claude API + transcription)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│ M1 Pro Mac (Host)                                                       │
│                                                                         │
│  ┌─────────────────┐                                                    │
│  │ mlx-audio       │     ┌──────────────────────────────────────────┐  │
│  │ VibeVoice-ASR   │ ──→ │ Google Drive (synced to cloud)           │  │
│  │ (transcription  │     │ ~/Google Drive/.../openclaw_agent/       │  │
│  │  + diarization) │     │ ├── workspace/MEMORY.md                  │  │
│  └─────────────────┘     │ └── transcripts/*.json                   │  │
│                          └──────────────────┬───────────────────────┘  │
│                                             │ VirtioFS                  │
│  ┌──────────────────────────────────────────┼───────────────────────┐  │
│  │ Lume VM                                  ↓                       │  │
│  │                       /mnt/workspace, /mnt/transcripts           │  │
│  │                                                                  │  │
│  │  ┌────────────────────────────────────────────────────────────┐ │  │
│  │  │ OpenClaw                                                   │ │  │
│  │  │ ├── Memory System (SQLite + embeddings)                   │ │  │
│  │  │ ├── Telegram Bot ──→ /mnt/media (backed up to NAS)        │ │  │
│  │  │ └── Claude Sonnet 4 (LLM)                                 │ │  │
│  │  └────────────────────────────────────────────────────────────┘ │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ NAS (/Volumes/NAS_1/Xin/openclaw_agent/media/)                   │  │
│  │ └── Telegram voice messages (backed up)                          │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

## File Organization

**What goes where:**

| Location | Contents | Backup |
|----------|----------|--------|
| Google Drive | Markdown files, transcripts | Cloud sync |
| NAS | Telegram audio files | NAS backup |
| VM only | Databases, config, sessions | Not synced (rebuildable) |
| Host local | Audio inbox, scripts | Not synced |

**Host Mac paths:**
```
~/Google Drive/My Drive/openclaw_agent/
├── workspace/              # Markdown files (synced to cloud)
│   ├── MEMORY.md
│   └── notes/
└── transcripts/            # Transcription output (synced to cloud)

/Volumes/NAS_1/Xin/openclaw_agent/
└── media/                  # Telegram voice messages (backed up to NAS)

~/openclaw_agent/           # Local only (not synced)
├── audio-inbox/            # Drop long recordings here
├── audio-archive/          # Processed recordings
└── scripts/                # transcribe.sh
```

**VM paths:**
```
~/.openclaw/                # Stays in VM (databases, config)
├── config.yaml
├── sessions/
├── agents/                 # SQLite databases
└── workspace -> /mnt/workspace   # Symlink to shared folder

/mnt/workspace/             # Mounted from Google Drive
/mnt/transcripts/           # Mounted from Google Drive
/mnt/media/                 # Mounted from NAS
```

---

## Table of Contents

1. [Host Setup (Mac)](#part-1-host-setup-mac)
2. [Lume VM Setup](#part-2-lume-vm-setup)
3. [OpenClaw Setup (VM)](#part-3-openclaw-setup-vm)
4. [Telegram Bot](#part-4-telegram-bot-setup)
5. [Daily Workflow](#part-5-daily-workflow)
6. [Cost Breakdown](#part-6-cost-summary)
7. [Troubleshooting](#troubleshooting)

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
python -m mlx_audio.stt.generate \
    --model mlx-community/VibeVoice-ASR-bf16 \
    --audio /tmp/test.aiff \
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

### 1.3 Install Transcription Script

Copy the transcription script:

```bash
mkdir -p ~/scripts
cp scripts/knowledge-base/transcribe.sh ~/scripts/
chmod +x ~/scripts/transcribe.sh
```

### 1.4 Create Directories

```bash
# Google Drive (synced to cloud)
mkdir -p ~/Google\ Drive/My\ Drive/openclaw_agent/workspace
mkdir -p ~/Google\ Drive/My\ Drive/openclaw_agent/transcripts

# NAS (backed up)
mkdir -p /Volumes/NAS_1/Xin/openclaw_agent/media

# Local only (not synced)
mkdir -p ~/openclaw_agent/audio-inbox
mkdir -p ~/openclaw_agent/audio-archive
mkdir -p ~/openclaw_agent/scripts
```

**Note:** Adjust paths based on your setup:
- Google Drive path depends on your sync location
- NAS path depends on your mount point
- Use `ln -s` to create shortcuts if needed

### 1.5 Test the Transcription Pipeline

```bash
# Create test recording
say "Hello, this is a test of the transcription system." -o ~/audio-inbox/test.aiff

# Run transcription
~/scripts/transcribe.sh

# Check output
ls ~/transcripts/
cat ~/transcripts/*test*.json
```

**Expected output:** JSON file with transcription, timestamps, and speaker labels.

### 1.6 Auto-Transcribe with launchd (Optional)

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
        <string>/Users/YOUR_USERNAME/scripts/transcribe.sh</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/Users/YOUR_USERNAME/audio-inbox</string>
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

# Test: drop a file in ~/audio-inbox and check logs
tail -f /tmp/transcribe.log
```

---

## Part 2: Lume VM Setup

### 2.1 Create VM

```bash
# Create Ubuntu VM (lighter than macOS)
lume create memory-app --os ubuntu --cpu 4 --memory 8192 --disk 50G

# Or macOS VM (if you prefer):
# lume create memory-app --os macos --cpu 4 --memory 8192 --disk 50G
```

### 2.2 Configure Shared Folders

Edit `~/.lume/vms/memory-app/config.yaml`:

```yaml
shared_directories:
  # Workspace (markdown files) - in Google Drive
  - host_path: /Users/YOUR_USERNAME/Google Drive/My Drive/openclaw_agent/workspace
    guest_path: /mnt/workspace
    read_only: false

  # Transcripts - in Google Drive
  - host_path: /Users/YOUR_USERNAME/Google Drive/My Drive/openclaw_agent/transcripts
    guest_path: /mnt/transcripts
    read_only: false

  # Telegram media - on NAS
  - host_path: /Volumes/NAS_1/Xin/openclaw_agent/media
    guest_path: /mnt/media
    read_only: false
```

Replace `YOUR_USERNAME` with your actual username.

### 2.3 Start VM

```bash
lume start memory-app
```

### 2.4 Verify Shared Folders

```bash
# SSH into VM
lume ssh memory-app

# Check mounts
ls /mnt/workspace
ls /mnt/transcripts
ls /mnt/media
```

All three folders should be accessible from the VM.

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

### 3.4 Configure Memory Paths

Point OpenClaw workspace to the shared folders:

```bash
# Symlink workspace to Google Drive mount
ln -sf /mnt/workspace ~/.openclaw/workspace

# Verify
ls -la ~/.openclaw/workspace/
ls /mnt/workspace/
ls /mnt/transcripts/
```

### 3.5 Create Memory Files (on Host)

Create initial memory file on your **host Mac** in Google Drive:

```bash
# On host Mac:
cat > ~/Google\ Drive/My\ Drive/openclaw_agent/workspace/MEMORY.md << 'EOF'
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
mkdir -p ~/Google\ Drive/My\ Drive/openclaw_agent/workspace/notes
```

This file will automatically appear in the VM at `/mnt/workspace/MEMORY.md` and sync to Google Drive.

### 3.6 Test Memory Search

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

# Set media download path to NAS-backed folder
openclaw config set tools.media.downloadPath "/mnt/media"
```

**What this does:**
- Telegram voice messages → downloaded to `/mnt/media` (in VM)
- `/mnt/media` → backed by NAS at `/Volumes/NAS_1/Xin/openclaw_agent/media/`
- Your voice messages automatically backed up to NAS

### 4.4 Configure Voice Transcription

OpenClaw auto-transcribes voice messages. Choose a provider:

**Option A: OpenAI Whisper (Recommended - simple)**
```bash
openclaw config set tools.media.audio.enabled true
openclaw config set tools.media.audio.language "en"
```

**Option B: Deepgram (Better for long audio + diarization)**
```bash
# Get key: https://console.deepgram.com/
openclaw config set providers.deepgram.apiKey "YOUR_KEY"
openclaw config set tools.media.audio.models '[{"provider": "deepgram", "model": "nova-3"}]'
```

**Option C: Groq (Fast + free tier)**
```bash
# Get key: https://console.groq.com/
openclaw config set providers.groq.apiKey "YOUR_KEY"
openclaw config set tools.media.audio.models '[{"provider": "groq", "model": "whisper-large-v3-turbo"}]'
```

### 4.5 Start Gateway

```bash
# Foreground (for testing)
openclaw gateway run

# Background (for production)
nohup openclaw gateway run > /tmp/openclaw.log 2>&1 &
```

### 4.6 Test Your Bot

1. Open Telegram → search for your bot
2. Send `/start`
3. Send "Hello!"
4. Bot should respond

Try voice:
- Hold mic button → "Testing voice transcription" → release
- Bot should reply with transcribed text

---

## Part 5: Daily Workflow

### 5.1 Quick Voice Memos

**Via Telegram voice message:**
1. Open bot → hold mic → speak → release
2. Bot transcribes and responds

Examples:
```
"Remember that John prefers morning meetings"
"Note: API deadline is March 15th"
"Todo: review security proposal tomorrow"
```

### 5.2 Short Meetings (< 1 hour)

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

### 5.3 Long Meetings (> 1 hour)

**Use host transcription:**

```bash
# On host Mac:
# 1. Record to ~/audio-inbox/meeting-2024-01-15.m4a
# 2. Transcription runs automatically (or manually):
~/scripts/transcribe.sh

# Output appears in ~/transcripts/
# VM sees it at /mnt/transcripts/
```

Then tell bot:
```
"Index the meeting from January 15th and summarize"
```

### 5.4 Query Your Memory

Send to bot (text or voice):
```
"What did we discuss yesterday?"
"What are John's preferences?"
"Summarize this week's decisions"
"Find tasks for the frontend"
"What was decided about the API?"
```

### 5.5 Store Important Info

```
"Remember: AWS account ID is 123456789"
"Store: production needs 2 approvers"
"Important: Sarah is on vacation Feb 1-15"
```

### 5.6 Daily Review

End of day:
```
"Summarize everything I noted today and list action items"
```

---

## Part 6: Reminders

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

## Part 7: Backup and Sync Strategy

### What Gets Backed Up

| Data | Location | Backup Method | Why |
|------|----------|---------------|-----|
| **Markdown files** | Google Drive | Cloud sync | Your actual knowledge |
| **Transcripts** | Google Drive | Cloud sync | Searchable text from audio |
| **Voice messages** | NAS | NAS backup | Original audio files |
| **Databases** | VM only | Not backed up | Rebuildable from markdown |
| **Config/credentials** | VM only | Manual backup | Sensitive, manual only |

### How Sync Works

```
┌────────────────────────────────────────────────────────────────┐
│ Your workflow:                                                 │
│                                                                │
│ 1. Send voice memo to Telegram                                │
│    ↓                                                           │
│ 2. OpenClaw downloads to /mnt/media → NAS backup              │
│    ↓                                                           │
│ 3. OpenClaw transcribes via API                               │
│    ↓                                                           │
│ 4. Agent writes notes to /mnt/workspace → Google Drive        │
│    ↓                                                           │
│ 5. Your markdown files sync to cloud automatically            │
└────────────────────────────────────────────────────────────────┘
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

1. **Your data is safe** - markdown in Google Drive, audio on NAS
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

## Part 8: Cost Summary

### Recommended Setup: Telegram + Deepgram + Sonnet API

| Component | Monthly Cost |
|-----------|--------------|
| Claude Sonnet 4 (~1.2M tokens) | ~$6 |
| OpenAI Embeddings (~100K tokens) | ~$0.10 |
| Deepgram transcription (~2400 min) | ~$10 |
| **Total** | **~$16/month** |

### Usage Estimates

- Voice memos: 20/day × 1 min = 600 min/month
- Meetings: 3/week × 1 hour = 720 min/month
- Long recordings (host): 2/month × 2 hours = free (mlx-audio)
- LLM queries: ~40/day × ~30K tokens = 1.2M tokens/month

### Alternative Options

**Option A: All cloud (OpenAI Whisper)**
- Total: ~$20/month
- Pros: Simpler, no local processing
- Cons: $4/month more expensive

**Option B: Hybrid (Telegram + host mlx-audio)**
- Total: ~$8/month
- Pros: Cheapest, privacy, built-in diarization
- Cons: Manual workflow for long meetings

**Option C: Groq free tier**
- Total: ~$6/month
- Pros: Cheapest
- Cons: Rate limits, no diarization

---

## Part 8: Getting Claude API Access

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
# Check Lume config
cat ~/.lume/vms/memory-app/config.yaml

# Restart VM
lume restart memory-app

# Check mount inside VM
lume ssh memory-app
mount | grep transcripts
```

### Memory Not Indexing

```bash
# Force reindex
openclaw memory index --force

# Check status
openclaw memory status --deep

# Verify paths
ls ~/.openclaw/workspace/
ls /mnt/transcripts/
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

**Check provider config:**
```bash
openclaw config get tools.media.audio
openclaw config get providers.openai.apiKey
# or
openclaw config get providers.deepgram.apiKey
```

**Test manually:**
```bash
# Record test
echo "Test" | say -o /tmp/test.aiff

# Upload to bot as voice message
# Check logs for errors
```

**File too large:**
```bash
# Increase limit
openclaw config set channels.telegram.mediaMaxMb 50

# Or use host transcription for large files
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
      paths: ["/mnt/transcripts/work"]

  personal:
    personality: "Casual assistant for personal notes"
    memorySearch:
      paths: ["/mnt/transcripts/personal"]
```

### 4. Backup Strategy

```bash
# Backup script
#!/bin/bash
BACKUP_DIR=~/backups/openclaw-$(date +%Y-%m-%d)
mkdir -p "$BACKUP_DIR"

# Backup config and memory
cp -r ~/.openclaw "$BACKUP_DIR/"

# Backup transcripts
cp -r ~/transcripts "$BACKUP_DIR/"

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
A: Yes, that's the default. OpenClaw indexes everything under `~/.openclaw/workspace/` and `/mnt/transcripts/`.

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
