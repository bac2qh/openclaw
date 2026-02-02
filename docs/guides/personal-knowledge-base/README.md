# Personal Knowledge Base with OpenClaw

Build a voice-powered memory system using OpenClaw, mlx-whisper, pyannote, Lume VM, and Claude Sonnet 4.

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
┌─────────────────────────────────────────────────────────────────┐
│ M1 Pro Mac (Host)                                               │
│                                                                 │
│  ┌─────────────────┐     ┌─────────────────────────────────┐   │
│  │ mlx-whisper     │     │ ~/transcripts/ (shared folder)  │   │
│  │ (Apple MLX)     │ ──→ │ ├── meeting-2024-01-15.txt      │   │
│  ├─────────────────┤     │ └── meeting-2024-01-16.txt      │   │
│  │ pyannote        │     └───────────────┬─────────────────┘   │
│  │ (diarization)   │                     │ VirtioFS            │
│  └─────────────────┘                     │                     │
│  ┌───────────────────────────────────────┼─────────────────┐   │
│  │ Lume VM                               ↓                 │   │
│  │                     /mnt/transcripts/ (mounted)         │   │
│  │                                                         │   │
│  │  ┌─────────────────────────────────────────────────┐   │   │
│  │  │ OpenClaw                                        │   │   │
│  │  │ ├── Memory System (SQLite + embeddings)        │   │   │
│  │  │ ├── Telegram Bot (voice memos)                 │   │   │
│  │  │ └── Claude Sonnet 4 (LLM)                      │   │   │
│  │  └─────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
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

### 1.2 Install mlx-whisper (Transcription)

mlx-whisper uses Apple's MLX framework for native M1/M2/M3 GPU acceleration.

```bash
# Install ffmpeg (required for audio conversion)
brew install ffmpeg

# Install mlx-whisper
pip install mlx-whisper

# Test it works
say "Hello, this is a test." -o /tmp/test.aiff
mlx_whisper /tmp/test.aiff --model mlx-community/whisper-large-v3-mlx
```

**Expected output:**
Creates `/tmp/test.txt` with transcription.

**Available models (from mlx-community on Hugging Face):**

| Model | Size | Use Case |
|-------|------|----------|
| `mlx-community/whisper-large-v3-mlx` | ~3GB | **Best accuracy** (recommended) |
| `mlx-community/whisper-large-v3-turbo` | ~1.6GB | Fast + good accuracy |
| `mlx-community/whisper-medium-mlx` | ~1.5GB | Balanced |
| `mlx-community/whisper-small-mlx` | ~500MB | Quick tests |

### 1.3 Install pyannote (Speaker Diarization)

pyannote identifies who spoke when in meetings.

```bash
# Create virtual environment
python3 -m venv ~/diarize-env
source ~/diarize-env/bin/activate

# Install dependencies
pip install pyannote.audio torch torchaudio

# Verify
python -c "from pyannote.audio import Pipeline; print('pyannote OK')"
```

**Hugging Face Setup (required):**

1. Create account: https://huggingface.co/
2. Accept model terms:
   - https://huggingface.co/pyannote/speaker-diarization-3.1
   - https://huggingface.co/pyannote/segmentation-3.0
3. Create token: https://huggingface.co/settings/tokens (Read access)
4. Save token: `export HF_TOKEN="hf_your_token_here"`

### 1.4 Install Diarization Script

Copy the script from `scripts/knowledge-base/diarize.py` to `~/scripts/`:

```bash
mkdir -p ~/scripts
cp scripts/knowledge-base/diarize.py ~/scripts/
chmod +x ~/scripts/diarize.py
```

Test it:
```bash
# Create test audio
say "Hello, this is speaker one. And this is speaker two." -o /tmp/test.aiff

# Run diarization
export HF_TOKEN="hf_your_token_here"
source ~/diarize-env/bin/activate
python ~/scripts/diarize.py /tmp/test.aiff
```

**Expected output:**
```
[0.0s - 2.5s] SPEAKER_00
[2.5s - 5.0s] SPEAKER_01
```

### 1.5 Install Transcription Script

Copy the combined script:

```bash
cp scripts/knowledge-base/transcribe.sh ~/scripts/
chmod +x ~/scripts/transcribe.sh
```

Edit the script to set your HF token:
```bash
# Open in editor
nano ~/scripts/transcribe.sh

# Or use sed
sed -i '' 's/hf_your_token_here/YOUR_ACTUAL_TOKEN/g' ~/scripts/transcribe.sh
```

### 1.6 Create Directories

```bash
mkdir -p ~/audio-inbox      # Drop recordings here
mkdir -p ~/transcripts      # Output (shared with VM)
mkdir -p ~/audio-archive    # Processed files
```

### 1.7 Test the Transcription Pipeline

```bash
# Create test recording
say "Hello, this is a test of the transcription system." -o ~/audio-inbox/test.aiff

# Run transcription
~/scripts/transcribe.sh

# Check output
ls ~/transcripts/
cat ~/transcripts/*test*.txt
cat ~/transcripts/*test*.speakers.txt
```

### 1.8 Auto-Transcribe with launchd (Optional)

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
        <key>HF_TOKEN</key>
        <string>hf_your_token_here</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/transcribe.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/transcribe.err</string>
</dict>
</plist>
```

Replace `YOUR_USERNAME` and `hf_your_token_here`, then load:

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

### 2.2 Configure Shared Folder

Edit `~/.lume/vms/memory-app/config.yaml`:

```yaml
shared_directories:
  - host_path: /Users/YOUR_USERNAME/transcripts
    guest_path: /mnt/transcripts
    read_only: false
```

Replace `YOUR_USERNAME` with your actual username.

### 2.3 Start VM

```bash
lume start memory-app
```

### 2.4 Verify Shared Folder

```bash
# SSH into VM
lume ssh memory-app

# Check mount
ls /mnt/transcripts
```

You should see your transcribed files from the host.

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

Add transcripts folder to memory:

```bash
# Create symlink
mkdir -p ~/.openclaw/workspace
ln -s /mnt/transcripts ~/.openclaw/workspace/transcripts

# Verify
ls -la ~/.openclaw/workspace/
```

### 3.5 Create Memory Workspace

```bash
mkdir -p ~/.openclaw/workspace/memory

cat > ~/.openclaw/workspace/MEMORY.md << 'EOF'
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
```

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
```

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

## Part 7: Cost Summary

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
- Long recordings (host): 2/month × 2 hours = free (mlx-whisper)
- LLM queries: ~40/day × ~30K tokens = 1.2M tokens/month

### Alternative Options

**Option A: All cloud (OpenAI Whisper)**
- Total: ~$20/month
- Pros: Simpler, no local processing
- Cons: $4/month more expensive

**Option B: Hybrid (Telegram + host mlx-whisper)**
- Total: ~$8/month
- Pros: Cheapest, privacy
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

### mlx-whisper Issues

**Model not downloading:**
```bash
# Models auto-download from Hugging Face on first use
# If issues, try explicit download:
pip install huggingface_hub
huggingface-cli download mlx-community/whisper-large-v3-mlx
```

**Slow transcription:**
- Ensure you're on Apple Silicon (M1/M2/M3)
- Check Activity Monitor → GPU usage
- Try smaller model: `mlx-community/whisper-large-v3-turbo`

**ImportError or pip issues:**
```bash
# Use a virtual environment
python3 -m venv ~/mlx-env
source ~/mlx-env/bin/activate
pip install mlx-whisper
```

### pyannote Issues

**Authentication error:**
```bash
# Verify token
echo $HF_TOKEN

# Check model access on Hugging Face
# Ensure you accepted terms for both models
```

**ImportError:**
```bash
# Reinstall
source ~/diarize-env/bin/activate
pip install --upgrade pyannote.audio torch torchaudio
```

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
A: Voice transcription and LLM queries go to cloud APIs. For maximum privacy, use mlx-whisper + local LLM (Ollama). mlx-whisper runs 100% locally on your M1/M2/M3 Mac.

**Q: Can I run this on Linux?**
A: Yes, the VM setup works the same. For host transcription on Linux (or Intel Mac), use whisper.cpp or OpenAI Whisper instead of mlx-whisper.

**Q: What if I want speaker names (not SPEAKER_00)?**
A: pyannote doesn't do speaker identification (who is who), only diarization (how many speakers). For names, use a service like AssemblyAI or manually label.

**Q: Can I search across all memories at once?**
A: Yes, that's the default. OpenClaw indexes everything under `~/.openclaw/workspace/` and `/mnt/transcripts/`.

---

## Resources

- **OpenClaw Docs**: https://docs.openclaw.ai/
- **Telegram Bot API**: https://core.telegram.org/bots/api
- **mlx-whisper**: https://github.com/ml-explore/mlx-examples/tree/main/whisper
- **pyannote**: https://github.com/pyannote/pyannote-audio
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
