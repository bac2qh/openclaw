---
summary: "Build a voice-powered personal memory system with OpenClaw, Telegram, and Claude Sonnet 4"
read_when:
  - Building a personal knowledge management system
  - Setting up voice memo transcription and memory search
  - Creating an AI-powered memory bot
title: "Personal Knowledge Base with OpenClaw"
---

# Personal Knowledge Base with OpenClaw

Build a voice-powered memory app using OpenClaw, Telegram, and Claude Sonnet 4. Record voice memos, meetings, and notes via Telegram, and query your knowledge base with natural language.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│ M1 Pro Mac (Host)                                               │
│                                                                 │
│  ┌─────────────────┐     ┌─────────────────────────────────┐   │
│  │ WhisperX        │     │ ~/transcripts/ (shared folder)  │   │
│  │ (GPU-accelerated)│ ──→ │ ├── 2024-01-15-meeting.txt     │   │
│  └─────────────────┘     │ └── 2024-01-16-memo.txt        │   │
│                          └───────────────┬─────────────────┘   │
│                                          │ Shared via Lume      │
│  ┌───────────────────────────────────────┼─────────────────┐   │
│  │ Lume VM (Ubuntu/macOS)                ↓                 │   │
│  │                     /mnt/transcripts/ (mounted)         │   │
│  │                                                         │   │
│  │  ┌─────────────────────────────────────────────────┐   │   │
│  │  │ OpenClaw                                        │   │   │
│  │  │ ├── Memory System (SQLite + embeddings)        │   │   │
│  │  │ ├── Telegram Bot (voice memos)                 │   │   │
│  │  │ └── Claude Sonnet 4 (LLM)                      │   │   │
│  │  └─────────────────────────────────────────────────┘   │   │
│  │                                                         │   │
│  │  ~/.openclaw/workspace/                                 │   │
│  │  ├── MEMORY.md                                          │   │
│  │  ├── memory/YYYY-MM-DD.md                               │   │
│  │  └── transcripts/ → /mnt/transcripts (symlink)         │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘

Why this architecture:
- WhisperX on host: Free GPU-accelerated transcription (no API costs)
- OpenClaw in VM: Security isolation, API keys stay in VM
- Shared folder: Transcripts flow from host → VM → indexed by memory search
```

## Prerequisites

### Host Machine (M1 Pro Mac)
- **macOS** with Apple Silicon (M1/M2/M3)
- **Homebrew** package manager
- **Lume** for VM management
- **Miniforge** for WhisperX
- **Hugging Face account** (for speaker diarization)

### VM Requirements
- **Node.js 22+** (inside VM)
- **4GB+ RAM** allocated to VM
- **20GB+ disk** space

### API Keys
- **Anthropic API key** for Claude Sonnet 4 (~$6/month)
- **OpenAI API key** for embeddings (~$0.10/month)
- **Telegram account** for the bot interface

### Why Lume VM?
- **Security isolation**: API keys and bot tokens stay inside VM
- **Clean separation**: WhisperX on host GPU, OpenClaw in VM
- **Easy backup**: VM is self-contained

---

## Part 1: Host Setup (M1 Pro Mac)

### 1.1 Install Lume

```bash
# Install Lume CLI
brew install lume

# Verify installation
lume --version
```

### 1.2 Install WhisperX

```bash
# Install Miniforge (conda for Apple Silicon)
brew install miniforge
conda init zsh  # or bash
# Restart terminal

# Create WhisperX environment
conda create -n whisperx python=3.10 -y
conda activate whisperx

# Install PyTorch for Apple Silicon
pip install torch torchvision torchaudio

# Install WhisperX
pip install whisperx

# For speaker diarization (meeting recordings):
# 1. Get token at: https://huggingface.co/settings/tokens
# 2. Accept terms at: https://huggingface.co/pyannote/speaker-diarization-3.1
```

### 1.3 Create Transcription Script

Create `~/scripts/transcribe.sh`:

```bash
#!/bin/bash
# Transcribe audio files with WhisperX (GPU-accelerated, free)

INPUT_DIR="$HOME/audio-inbox"
OUTPUT_DIR="$HOME/transcripts"
ARCHIVE_DIR="$HOME/audio-archive"
HF_TOKEN="hf_..."  # Your Hugging Face token

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$ARCHIVE_DIR"

# Activate conda environment
eval "$(conda shell.bash hook)"
conda activate whisperx

for audio_file in "$INPUT_DIR"/*.{mp3,m4a,wav,mp4,ogg}; do
    [ -e "$audio_file" ] || continue

    filename=$(basename "$audio_file" | sed 's/\.[^.]*$//')
    timestamp=$(date +%Y-%m-%d-%H%M)

    echo "Transcribing: $filename"

    # Use large-v3 for best accuracy (M1 Pro can handle it)
    whisperx "$audio_file" \
        --model large-v3 \
        --diarize \
        --hf_token "$HF_TOKEN" \
        --output_dir "$OUTPUT_DIR" \
        --output_format txt \
        --language en

    # Rename with timestamp
    if [ -f "$OUTPUT_DIR/$filename.txt" ]; then
        mv "$OUTPUT_DIR/$filename.txt" "$OUTPUT_DIR/${timestamp}-${filename}.txt"
        echo "✓ Saved: ${timestamp}-${filename}.txt"
    fi

    # Archive processed file
    mv "$audio_file" "$ARCHIVE_DIR/"
done
```

Make executable:
```bash
chmod +x ~/scripts/transcribe.sh
```

### 1.4 Create Shared Folders

```bash
mkdir -p ~/transcripts        # WhisperX output, shared with VM
mkdir -p ~/audio-inbox        # Drop recordings here
mkdir -p ~/audio-archive      # Processed files go here
```

### 1.5 Optional: Auto-Transcribe with launchd

For automatic transcription when you drop files in `~/audio-inbox`:

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
    <key>StandardOutPath</key>
    <string>/tmp/transcribe.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/transcribe.err</string>
</dict>
</plist>
```

Load it:
```bash
launchctl load ~/Library/LaunchAgents/com.user.transcribe.plist
```

### 1.6 Test WhisperX

```bash
# Test with a short audio file
conda activate whisperx
echo "Testing WhisperX" | say -o ~/audio-inbox/test.aiff
~/scripts/transcribe.sh

# Check output
ls -lh ~/transcripts/
```

---

## Part 2: Lume VM Setup

### 2.1 Create VM

```bash
# Create Ubuntu VM (lighter than macOS)
lume create openclaw-memory --os ubuntu --cpu 4 --memory 4096 --disk 20G

# Or macOS VM (if you prefer)
# lume create openclaw-memory --os macos --cpu 4 --memory 8192 --disk 30G
```

### 2.2 Configure Shared Folder

Add shared folder for transcripts:

```bash
# Edit VM config
lume config openclaw-memory
```

Add this to the config file:

```yaml
shared_directories:
  - host_path: /Users/YOUR_USERNAME/transcripts
    guest_path: /mnt/transcripts
    read_only: false
```

Or use CLI flag when starting:

```bash
lume start openclaw-memory --share ~/transcripts:/mnt/transcripts
```

### 2.3 Start and SSH into VM

```bash
# Start VM
lume start openclaw-memory

# SSH into VM
lume ssh openclaw-memory
```

You're now inside the VM. All following steps happen inside the VM.

---

## Part 3: Install OpenClaw (Inside VM)

**⚠️ You should now be inside the VM via `lume ssh openclaw-memory`**

### 3.1 Install Prerequisites (Ubuntu)

```bash
# Update package list
sudo apt update
sudo apt install -y curl git build-essential

# Install Node.js 22+
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs

# Verify
node --version  # Should be 22.x
npm --version
```

### 3.2 Install OpenClaw

```bash
# Install globally
npm install -g openclaw@latest

# Verify installation
openclaw --version
```

### 3.3 Initialize Configuration

```bash
# Create default config
openclaw config init

# This creates ~/.openclaw/config.yaml
```

### 3.4 Verify Shared Folder

```bash
# Check if transcripts folder is mounted
ls /mnt/transcripts

# If empty, that's fine - WhisperX will create files here from the host
```

---

## Part 4: Configure Claude Sonnet 4 (Inside VM)

### 2.1 Get Anthropic API Access

1. **Create account**: https://console.anthropic.com/
2. **Add payment method**: Settings → Billing
3. **Create API key**: Settings → API Keys → Create Key
4. **Copy the key**: Starts with `sk-ant-...`

**Important**: You need the **API**, not Claude Pro subscription. The API is pay-as-you-go (~$6/month for typical personal use), while Claude Pro ($20/month) is for the web interface only and won't work with OpenClaw.

### 2.2 Configure OpenClaw

```bash
# Set Claude Sonnet 4 as the model
openclaw config set agents.defaults.model "claude-sonnet-4-20250514"

# Set your Anthropic API key
openclaw config set providers.anthropic.apiKey "sk-ant-..."

# Verify
openclaw config get agents.defaults.model
```

---

## Part 5: Configure Memory Search (Inside VM)

### 3.1 Enable Memory Search with Embeddings

```bash
# Enable memory search
openclaw config set agents.defaults.memorySearch.enabled true

# Set OpenAI as embedding provider
openclaw config set agents.defaults.memorySearch.provider "openai"
openclaw config set providers.openai.apiKey "sk-..."

# Or use Gemini for embeddings (cheaper)
# openclaw config set agents.defaults.memorySearch.provider "gemini"
# openclaw config set providers.google.apiKey "..."
```

### 3.2 Create Memory Workspace

```bash
# Create workspace directory
mkdir -p ~/.openclaw/workspace/memory

# Create initial memory file
cat > ~/.openclaw/workspace/MEMORY.md << 'EOF'
# Long-Term Memory

## About Me
- Name: [Your Name]
- Role: [Your Role]

## Preferences
- [Add your preferences]

## Important Information
- [Add important facts]

## Key Decisions
- [Decisions will be added here]
EOF
```

### 5.3 Link Transcripts Folder to Memory

```bash
# Create symlink to shared transcripts folder
ln -s /mnt/transcripts ~/.openclaw/workspace/transcripts

# Add to memory search paths
openclaw config set agents.defaults.memorySearch.extraPaths '["/mnt/transcripts"]'

# Now WhisperX transcripts will be automatically indexed!
```

---

## Part 6: Set Up Telegram Bot (Inside VM)

### 4.1 Create Telegram Bot

1. Open Telegram, search for `@BotFather`
2. Send `/newbot`
3. Choose a name: `My Memory Bot`
4. Choose a username: `my_memory_bot` (must end in `bot`)
5. Copy the bot token (looks like `123456:ABC-DEF...`)
6. Find your Telegram user ID:
   - Message `@userinfobot` on Telegram
   - Copy your user ID (numeric)

### 4.2 Configure Telegram Channel

```bash
# Set Telegram bot token
openclaw config set channels.telegram.botToken "YOUR_BOT_TOKEN"

# Set your user ID for allowlist (replace with your actual ID)
openclaw config set channels.telegram.allowFrom '["YOUR_TELEGRAM_USER_ID"]'

# Set max media size (for longer voice messages)
openclaw config set channels.telegram.mediaMaxMb 20

# Enable DM policy (pairing mode by default)
openclaw config set channels.telegram.dmPolicy "pairing"
```

### 6.3 Configure Voice Transcription

You have two options for transcribing voice memos sent via Telegram:

#### Option A: Use WhisperX Only (100% Free, Private)

Telegram voice messages are usually short (< 5 minutes). You can:
1. Send voice message → bot saves audio file
2. Forward/download to host → run WhisperX manually
3. Ask bot: "Check the transcripts folder for my memo"

**No API configuration needed!** Skip to Part 7.

#### Option B: Use API for Short Memos (Convenient, Small Cost)

For convenience, let OpenClaw auto-transcribe short Telegram voice messages, but use WhisperX for longer recordings.

**Groq (Recommended - Free Tier):**
```bash
# Get free API key from https://console.groq.com/
openclaw config set providers.groq.apiKey "YOUR_GROQ_KEY"
openclaw config set tools.media.audio.enabled true
openclaw config set tools.media.audio.models '[{"provider": "groq", "model": "whisper-large-v3-turbo"}]'
```

**OpenAI (Paid but accurate):**
```bash
# Uses your existing OpenAI API key
openclaw config set tools.media.audio.enabled true
openclaw config set tools.media.audio.models '[{"provider": "openai", "model": "gpt-4o-mini-transcribe"}]'
```
**Pricing**: $0.006/minute (~$1/month for casual use)

**My recommendation**: Start with no API transcription (Option A), see if the manual workflow works for you. Add Groq later if you want convenience for short memos.

---

## Part 7: Start OpenClaw Gateway (Inside VM)

### 5.1 Start the Gateway

```bash
# Start gateway in foreground (to see logs)
openclaw gateway run

# Or run in background
nohup openclaw gateway run > ~/openclaw-gateway.log 2>&1 &
```

### 5.2 Verify Everything Works

```bash
# Check channel status
openclaw channels status

# Check memory search status
openclaw memory status

# View gateway logs (if running in background)
tail -f ~/openclaw-gateway.log
```

### 5.3 Test the Bot

1. Open Telegram
2. Search for your bot username
3. Send a message: "Hello!"
4. Bot should respond (you may need to approve pairing first)
5. Send a voice message: "Testing voice transcription"
6. Bot should transcribe and respond

---

## Part 8: Daily Workflow

### 6.1 Voice Memos (Quick Notes)

**Via Telegram voice message:**
1. Open Telegram → your bot
2. Hold mic button → speak → release
3. Bot transcribes and responds

Examples:
- "Remember that John prefers morning meetings"
- "Note: API deadline moved to March 15th"
- "Todo: review the security proposal tomorrow"

### 8.2 Meeting Recording (WhisperX on Host)

**For meetings, use WhisperX for best accuracy and zero cost:**

1. **Record on host Mac:**
   ```bash
   # Use QuickTime, Voice Memos, or any recording app
   # Save to ~/audio-inbox/meeting-2024-01-15.m4a
   ```

2. **Transcribe with WhisperX:**
   ```bash
   # On host Mac (exit VM first: type 'exit')
   ~/scripts/transcribe.sh

   # Or just drop file in ~/audio-inbox/ if launchd is running
   ```

3. **Verify transcript:**
   ```bash
   # Check output
   ls -lh ~/transcripts/
   cat ~/transcripts/2024-01-15-*-meeting.txt
   ```

4. **Query from Telegram:**
   - Message your bot: "Summarize the meeting from January 15th"
   - Bot will search transcripts and respond

**Why WhisperX for meetings:**
- ✅ Free (no API costs)
- ✅ Accurate (large-v3 model)
- ✅ Speaker diarization (who said what)
- ✅ Private (no audio sent to cloud)
- ✅ Unlimited length (2+ hour meetings OK)

### 6.3 Query Your Knowledge Base

Send text or voice to Telegram bot:
- "What did we discuss in yesterday's meeting?"
- "What are John's preferences?"
- "Summarize all decisions from this week"
- "What tasks did I mention for the frontend?"
- "Find everything about the API redesign"

Memory search automatically searches your `MEMORY.md`, daily notes, and any extra paths you configured.

### 6.4 Store Important Information

Send to bot:
- "Remember: our AWS account ID is 123456789"
- "Store this: production deploy requires 2 approvers"
- "Important: Sarah is on vacation Feb 1-15"

The agent will write to `MEMORY.md` or daily notes (`memory/YYYY-MM-DD.md`) automatically.

### 6.5 Daily Review

End of day, send:
"Summarize everything I noted today and list any action items"

---

## Part 9: Set Up Reminders (Inside VM)

OpenClaw has a built-in cron system that can send you Telegram reminders.

### 7.1 Natural Language Reminders

Just ask the bot:
- "Remind me in 20 minutes to check the build"
- "Remind me tomorrow at 9am about the standup"
- "Set a daily reminder at 6pm to write journal"
- "Remind me every Monday at 10am to review metrics"

The agent will create cron jobs automatically and send reminders to your Telegram.

### 7.2 Manage Reminders

Ask the bot:
- "List my reminders"
- "Cancel the morning standup reminder"
- "Show all scheduled jobs"

Or via CLI:
```bash
# List all cron jobs
openclaw cron list

# Remove a job
openclaw cron remove <job-id>

# View job details
openclaw cron status --id <job-id>
```

### 7.3 Manual Reminder Setup (CLI)

```bash
# One-shot reminder
openclaw cron add \
  --name "Check the build" \
  --at "2026-02-01T14:00:00-08:00" \
  --session isolated \
  --message "Reminder: check the build" \
  --deliver \
  --channel telegram \
  --delete-after-run

# Recurring reminder
openclaw cron add \
  --name "Daily journal" \
  --cron "0 18 * * *" \
  --tz "America/Los_Angeles" \
  --session isolated \
  --message "Reminder: write your journal" \
  --deliver \
  --channel telegram
```

---

## Part 10: Configuration Reference

### Full Configuration Example

Save this to `~/.openclaw/config.yaml`:

```yaml
# ~/.openclaw/config.yaml

agents:
  defaults:
    model: "claude-sonnet-4-20250514"
    memorySearch:
      enabled: true
      provider: "openai"  # or "gemini"
      sources:
        - memory
      extraPaths:
        - "/path/to/extra/notes"
      sync:
        watch: true
        onSessionStart: true
      query:
        maxResults: 6
        minScore: 0.35

providers:
  anthropic:
    apiKey: "sk-ant-..."
  openai:
    apiKey: "sk-..."
  # Optional: Deepgram for audio
  deepgram:
    apiKey: "..."
  # Optional: Gemini for embeddings
  google:
    apiKey: "..."

channels:
  telegram:
    enabled: true
    botToken: "123456:ABC..."
    dmPolicy: "pairing"
    allowFrom:
      - "YOUR_TELEGRAM_USER_ID"
    mediaMaxMb: 20
    streamMode: "partial"

tools:
  media:
    audio:
      enabled: true
      maxBytes: 26214400  # 25MB
      timeoutSeconds: 120
      language: "en"
      models:
        - provider: "deepgram"
          model: "nova-3"
        - provider: "openai"  # Fallback
          model: "gpt-4o-mini-transcribe"

cron:
  enabled: true
```

### Key Configuration Paths

| Setting | Default | Description |
|---------|---------|-------------|
| `agents.defaults.model` | `claude-sonnet-4-20250514` | LLM model |
| `agents.defaults.memorySearch.enabled` | `true` | Enable memory search |
| `agents.defaults.memorySearch.provider` | `auto` | Embedding provider |
| `agents.defaults.workspace` | `~/.openclaw/workspace` | Workspace path |
| `channels.telegram.botToken` | - | Telegram bot token |
| `channels.telegram.mediaMaxMb` | `5` | Max media download size |
| `tools.media.audio.enabled` | `true` | Enable audio transcription |
| `cron.enabled` | `true` | Enable cron scheduler |

### CLI Commands Reference

```bash
# Configuration
openclaw config init                          # Initialize config
openclaw config get <key>                     # Get config value
openclaw config set <key> <value>             # Set config value

# Gateway
openclaw gateway run                          # Start gateway
openclaw channels status                      # Check channel status

# Memory
openclaw memory status                        # Check memory status
openclaw memory index --force                 # Reindex memory
openclaw memory search "query"                # Search memory

# Cron
openclaw cron list                           # List all jobs
openclaw cron add <options>                  # Add a job
openclaw cron remove <job-id>                # Remove a job
openclaw cron run <job-id> --force           # Run a job now
```

---

## Part 11: Cost Summary

### Your Setup: Lume VM + WhisperX + Claude API

| Component | Monthly Cost | Usage |
|-----------|--------------|-------|
| Claude Sonnet 4 API | ~$6 | ~1.2M tokens |
| OpenAI Embeddings | ~$0.10 | ~100K tokens |
| WhisperX (host GPU) | **$0** | Unlimited, private |
| Groq (optional, short memos) | **$0** | Free tier |
| **Total** | **~$6/month** | |

**That's it!** Just $6/month for a complete personal knowledge base.

### Alternative: Add Paid Transcription for Telegram Convenience

If you want instant transcription of Telegram voice messages without downloading/processing:

| Additional Option | Monthly Cost | When to Use |
|-------------------|--------------|-------------|
| OpenAI Whisper API | +$1-2 | Casual voice memos |
| Deepgram API | +$10 | Heavy Telegram voice memo use |

### Transcription Accuracy Comparison

| Provider | Accuracy | Speed | Speaker Diarization | Cost |
|----------|----------|-------|---------------------|------|
| **WhisperX large-v3** | ⭐⭐⭐⭐⭐ Best | Medium | ✅ Yes | Free |
| **Deepgram nova-3** | ⭐⭐⭐⭐⭐ Best | Fast | ✅ Yes | $0.0043/min |
| OpenAI Whisper | ⭐⭐⭐⭐ Good | Fast | ❌ No | $0.006/min |
| Groq Whisper | ⭐⭐⭐⭐ Good | Very Fast | ❌ No | Free |

**For your M1 Pro**: WhisperX large-v3 is the most accurate option and completely free. Deepgram nova-3 is slightly more convenient (API) but costs money and isn't meaningfully more accurate.

---

## Part 12: Troubleshooting

### Lume VM Issues

**VM won't start:**
```bash
# On host Mac
lume status
lume start openclaw-memory

# Check logs
lume logs openclaw-memory
```

**Shared folder not visible in VM:**
```bash
# Inside VM
ls /mnt/transcripts

# If empty, restart VM with share flag
# On host: lume stop openclaw-memory
# On host: lume start openclaw-memory --share ~/transcripts:/mnt/transcripts
```

### Bot not responding (Inside VM)

```bash
# Check gateway is running
ps aux | grep openclaw

# Check channel status
openclaw channels status

# View logs
tail -f ~/openclaw-gateway.log
```

**Common issues:**
- Forgot to approve pairing (if using `dmPolicy: "pairing"`)
- User ID not in allowlist
- Gateway not running
- Wrong bot token

### WhisperX not transcribing (On Host)

```bash
# On host Mac (not in VM)
conda activate whisperx
which whisperx  # Should show path

# Test manually
whisperx ~/audio-inbox/test.m4a --model large-v3 --output_dir ~/transcripts --output_format txt

# Check logs
cat /tmp/transcribe.log
cat /tmp/transcribe.err
```

**Common issues:**
- Conda environment not activated
- Missing Hugging Face token (for diarization)
- Out of memory (use `--model medium` or `--model small`)
- Audio format not supported (convert to .m4a or .wav)

### Telegram voice transcription not working (Inside VM)

```bash
# Inside VM
openclaw config get tools.media.audio

# Check logs
tail -f ~/openclaw-gateway.log
```

**Common issues:**
- No API key set for audio provider (if using Groq/OpenAI)
- File size exceeds `mediaMaxMb`
- If using API-free setup, audio files need manual processing on host

### Memory search not finding things

```bash
# Force reindex
openclaw memory index --force

# Check memory status
openclaw memory status

# Verify embeddings provider is configured
openclaw config get agents.defaults.memorySearch.provider
```

**Common issues:**
- Embeddings provider not configured
- API key missing
- Memory files not in workspace
- Search score threshold too high

### Reminders not firing

```bash
# Check cron is enabled
openclaw config get cron.enabled

# List all jobs
openclaw cron list

# Check job details
openclaw cron status --id <job-id>
```

**Common issues:**
- Cron disabled in config
- Job schedule in wrong timezone
- Delivery channel not configured

---

## Next Steps

1. **Customize memory structure**: Edit `MEMORY.md` with your personal info
2. **Set up daily reminders**: Ask the bot to remind you to review notes
3. **Experiment with voice memos**: Record thoughts throughout the day
4. **Try meeting transcription**: Record a test meeting and query it
5. **Tune memory search**: Adjust `minScore` and `maxResults` for better results
6. **Add skills**: Explore OpenClaw skills for additional functionality

---

## Additional Resources

- [OpenClaw Documentation](https://docs.openclaw.ai/)
- [Telegram Channel Guide](/channels/telegram)
- [Memory System Guide](/concepts/memory)
- [Audio Transcription Guide](/nodes/audio)
- [Cron Jobs Guide](/automation/cron-jobs)
- [GitHub Repository](https://github.com/openclaw/openclaw)

---

## Support

- **Issues**: https://github.com/openclaw/openclaw/issues
- **Discussions**: https://github.com/openclaw/openclaw/discussions
- **Documentation**: https://docs.openclaw.ai/

---

**Happy memory building! 🧠**
