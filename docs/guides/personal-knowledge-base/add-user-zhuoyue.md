# Adding Zhuoyue as a Second User

This guide walks you through setting up a second OpenClaw instance for Zhuoyue alongside Xin's existing instance on the same Mac and VM. Each user gets isolated Telegram bots, media folders, transcripts, workspaces, memory databases, and gateway processes.

**What you'll set up:**
- `~/.openclaw-zhuoyue` state directory (VM)
- `~/openclaw/zhuoyue/` data folders (Mac host)
- Separate Telegram bot and agent for Zhuoyue
- Independent gateway on port 18790
- Isolated transcription pipeline with launchd

For architecture and multi-user concepts, see [README.md](./README.md).

---

## Prerequisites

Before starting, ensure the following are in place:

- **Xin's instance already running** on VM (port 18789)
- **Lume VM started** with shared directory: `lume run nix --shared-dir ~/openclaw`
- **Ollama running on host** at `0.0.0.0:11434` (for embeddings)
  ```bash
  # On host Mac - verify or start:
  OLLAMA_HOST=0.0.0.0 ollama serve
  ```
- **Zhuoyue's Telegram bot token** (from [@BotFather](https://t.me/BotFather))
- **Zhuoyue's Telegram user ID** (from [@userinfobot](https://t.me/userinfobot))
- **Moonshot API key** (for Kimi 2.5)

---

## Part 1: Host Mac Setup

### 1.1 Run host-setup.sh

Create Zhuoyue's directories on the Mac host:

```bash
# From repo root
scripts/knowledge-base/zhuoyue/host-setup.sh
```

**What this creates:**
- `~/openclaw/zhuoyue/media/inbound/` - Telegram audio lands here
- `~/openclaw/zhuoyue/transcripts/` - mlx-audio writes transcripts here
- `~/openclaw/zhuoyue/workspace/` - Markdown files (synced to Google Drive)
- `~/openclaw/zhuoyue/config/` - Hotwords and config files
- `~/Insync/bac2qh@gmail.com/Google Drive/openclaw/zhuoyue/` - Cloud backup
- `/Volumes/NAS_1/zhuoyue/openclaw/media/recordings/` - Audio archival (if NAS mounted)

### 1.2 Create Initial MEMORY.md

Create a personalized memory file for Zhuoyue:

```bash
cat > ~/openclaw/zhuoyue/workspace/MEMORY.md << 'EOF'
# Long-Term Memory

## About Me
- **Name**: Zhuoyue
- **Role**: [Your role/profession]
- **Location**: [Timezone]
- **Preferred language**: English

## Communication Preferences
- Be concise and direct
- Use bullet points for lists
- Highlight action items clearly

## Work Context

### Current Projects
- [Project 1]: [Brief description]

### Team Members
- [Name]: [Role, preferences]

## Personal Preferences

### Scheduling
- Prefer [morning/afternoon] meetings
- No meetings on [day]

### Tools & Tech
- Editor: [VS Code, Vim, etc.]
- Terminal: [iTerm, etc.]

## Decisions Log

<!-- Important decisions and their rationale -->

---

*Last updated: [Date]*
EOF
```

**Template reference:** See [scripts/knowledge-base/MEMORY-template.md](../../../scripts/knowledge-base/MEMORY-template.md) for the full template with all sections.

### 1.3 Install launchd Plist

Set up automatic transcription for Zhuoyue's audio files:

```bash
# Copy the plist
cp scripts/knowledge-base/zhuoyue/com.user.transcribe-zhuoyue.plist ~/Library/LaunchAgents/

# IMPORTANT: Edit to replace /Users/xin.ding/ with your actual macOS username
nano ~/Library/LaunchAgents/com.user.transcribe-zhuoyue.plist

# Load the plist
launchctl load ~/Library/LaunchAgents/com.user.transcribe-zhuoyue.plist

# Verify it's running
launchctl list | grep transcribe-zhuoyue
```

**Note:** The plist contains hardcoded paths like `/Users/xin.ding/openclaw/scripts/knowledge-base/zhuoyue/transcribe.sh`. Update these to match your actual macOS username before loading.

### 1.4 Test Host Pipeline (Optional)

Verify the transcription pipeline works end-to-end:

```bash
# Create test audio file
say "Testing Zhuoyue's transcription pipeline." -o ~/openclaw/zhuoyue/media/inbound/test.aiff

# Watch the logs (launchd should auto-trigger)
tail -f /tmp/transcribe-zhuoyue.log

# Check transcript output (should appear within ~30 seconds)
ls ~/openclaw/zhuoyue/transcripts/
cat ~/openclaw/zhuoyue/transcripts/*test*.json

# Check synced to Google Drive
ls ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/zhuoyue/transcripts/

# Check audio moved to NAS (if mounted)
ls /Volumes/NAS_1/zhuoyue/openclaw/media/recordings/
```

**Expected behavior:**
1. Audio file appears in `~/openclaw/zhuoyue/media/inbound/`
2. launchd triggers `transcribe.sh` within 5-10 seconds
3. Transcript appears in `~/openclaw/zhuoyue/transcripts/` (JSON format)
4. Transcript synced to Google Drive
5. Audio file moved to NAS
6. Original audio deleted from inbound folder

---

## Part 2: VM Setup

### 2.0 Export State Directory

**CRITICAL:** Set `OPENCLAW_STATE_DIR` for all commands in this section. Without this, commands will use the default `~/.openclaw/` and interfere with Xin's instance.

```bash
# SSH into VM
lume ssh nix

# Export for the entire session
export OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue
```

**Warning:** Forgetting to set `OPENCLAW_STATE_DIR` is the most common mistake. Consider adding a shell alias:

```bash
# Add to ~/.bashrc or ~/.zshrc
alias oc-zhuoyue='OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw'
```

### 2.1 Initialize Config

```bash
openclaw config init
```

### 2.2 Set Model and Provider

Configure Kimi 2.5 and Moonshot API:

```bash
# Set default model
openclaw config set agents.defaults.model "moonshot/kimi-2.5"

# Set API key (replace with actual key)
openclaw config set providers.moonshot.apiKey "sk-..."
```

### 2.3 Configure Memory Search

Set up memory indexing with Ollama embeddings:

```bash
# Enable memory search
openclaw config set agents.defaults.memorySearch.enabled true

# Set embedding provider (Ollama on host)
openclaw config set agents.defaults.memorySearch.provider "openai"
openclaw config set agents.defaults.memorySearch.remote.baseUrl "http://192.168.64.1:11434/v1"
openclaw config set agents.defaults.memorySearch.remote.apiKey "ollama"
openclaw config set agents.defaults.memorySearch.model "qwen3-embedding:0.6b"

# Disable batch embeddings (Ollama doesn't support OpenAI Batch API)
openclaw config set agents.defaults.memorySearch.remote.batch.enabled false

# Add Zhuoyue's transcripts to searchable paths
openclaw config set agents.defaults.memorySearch.extraPaths '["zhuoyue/transcripts"]'

# Enable session memory for automatic indexing (required for transcript-watcher)
openclaw config set agents.defaults.memorySearch.experimental.sessionMemory true
```

**Note:** `192.168.64.1` is the host gateway IP from inside a Lume VM. Verify with:
```bash
ip route | grep default
```

### 2.4 Configure Telegram

Set up Zhuoyue's Telegram bot:

```bash
# Set bot token (replace with actual token)
openclaw config set channels.telegram.token "ZHUOYUE_BOT_TOKEN"

# Set allowlist (replace with Zhuoyue's actual user ID)
openclaw config set channels.telegram.allowlist '["ZHUOYUE_USER_ID"]'

# Increase media size limit for voice messages
openclaw config set channels.telegram.mediaMaxMb 20

# Disable cloud transcription (use mlx-audio on host for 100% local processing)
openclaw config set tools.media.audio.enabled false
```

**Get credentials:**
- Bot token: Message [@BotFather](https://t.me/BotFather) → `/newbot`
- User ID: Message [@userinfobot](https://t.me/userinfobot)

### 2.5 Set Up Symlinks (BEFORE Creating Agents)

**Critical:** Create symlinks BEFORE adding agents so workspace is available during agent creation:

```bash
# Create media directory
mkdir -p ~/.openclaw-zhuoyue/media

# Symlink inbound to shared folder (Telegram audio lands here)
ln -sf "/Volumes/My Shared Files/zhuoyue/media/inbound" ~/.openclaw-zhuoyue/media/inbound

# Symlink workspace to shared folder (markdown files)
ln -sf "/Volumes/My Shared Files/zhuoyue/workspace" ~/.openclaw-zhuoyue/workspace

# Verify symlinks work
ls -la ~/.openclaw-zhuoyue/media/inbound
ls -la ~/.openclaw-zhuoyue/workspace
cat ~/.openclaw-zhuoyue/workspace/MEMORY.md
```

**Why this matters:** OpenClaw reads the workspace directory during agent creation. If the symlink doesn't exist, agent creation may fail or use an incorrect workspace path.

### 2.6 Create Agents

Create two agents for Zhuoyue:

```bash
# Main agent for interactive Telegram messages
openclaw agents add zhuoyue --workspace ~/.openclaw-zhuoyue/workspace

# Separate agent for long transcript processing (prevents blocking)
openclaw agents add transcript-processor --workspace ~/.openclaw-zhuoyue/workspace

# Verify agents exist
openclaw agents list
```

**Expected output:**
```
zhuoyue
transcript-processor
```

### 2.7 Index Memory

Build the initial memory index:

```bash
# Index workspace and transcripts
openclaw memory index --verbose

# Check status
openclaw memory status --deep
```

**Expected output:** Should show indexed files including `MEMORY.md` and any existing transcripts.

### 2.8 Configure Bindings

Route Telegram messages to Zhuoyue's agent based on user ID:

```bash
# Set agent binding (replace ZHUOYUE_USER_ID with actual ID)
openclaw config set bindings '[
  {
    "agentId": "zhuoyue",
    "match": {
      "channel": "telegram",
      "peer": {
        "kind": "direct",
        "id": "ZHUOYUE_USER_ID"
      }
    }
  }
]'

# Enable per-peer session isolation
openclaw config set session.dmScope per-peer
```

**What this does:**
- Telegram DMs from Zhuoyue's user ID → routed to `zhuoyue` agent
- Session history isolated per Telegram user
- Other users (like Xin on port 18789) won't see Zhuoyue's messages

### 2.9 Start Gateway

Start the gateway on a separate port (18790):

```bash
# Foreground (for testing)
openclaw gateway run --bind loopback --port 18790

# Background (for production)
nohup openclaw gateway run --bind loopback --port 18790 --force \
  > /tmp/openclaw-gateway-zhuoyue.log 2>&1 &

# Verify it's running
ss -ltnp | grep 18790
tail -n 50 /tmp/openclaw-gateway-zhuoyue.log
```

**Port convention:**
- Xin: 18789
- Zhuoyue: 18790

**Note:** The gateway persists configuration automatically. After VM reboot, just restart the gateway process - no need to reconfigure. See [README.md#32a-understanding-onboarding-and-persistence](./README.md#32a-understanding-onboarding-and-persistence) for details.

### 2.10 Start Transcript Watcher

Set up automatic transcript processing in a persistent tmux session:

```bash
# Create tmux session (replace ZHUOYUE_CHAT_ID with actual ID)
tmux new-session -d -s transcript-watcher-zhuoyue \
  "OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue TELEGRAM_CHAT_ID=ZHUOYUE_CHAT_ID /Volumes/My\ Shared\ Files/scripts/knowledge-base/zhuoyue/transcript-watcher.sh"

# Attach to view logs
tmux attach -t transcript-watcher-zhuoyue

# Detach: Ctrl+B, then D
```

**Environment variables required:**
- `OPENCLAW_STATE_DIR`: Points to Zhuoyue's state directory
- `TELEGRAM_CHAT_ID`: Zhuoyue's Telegram user ID (same as in bindings)

**What this does:**
1. Watches `/Volumes/My Shared Files/zhuoyue/transcripts/` for new JSON files
2. Short transcripts (<10 min) → processed in main session (full conversational context)
3. Long transcripts (≥10 min) → processed by `transcript-processor` agent (avoids blocking)
4. Sends summary/action items back to Telegram
5. Archives processed transcripts to `processed/` subfolder

**To stop the watcher:**
```bash
tmux kill-session -t transcript-watcher-zhuoyue
```

---

## Verification Checklist

After completing all steps, verify everything works:

### VM Setup
- [ ] State directory exists: `ls ~/.openclaw-zhuoyue/`
- [ ] Agents exist: `OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw agents list`
- [ ] Symlinks correct:
  - [ ] `ls -la ~/.openclaw-zhuoyue/media/inbound` → points to shared folder
  - [ ] `ls -la ~/.openclaw-zhuoyue/workspace` → points to shared folder
  - [ ] `cat ~/.openclaw-zhuoyue/workspace/MEMORY.md` → shows content
- [ ] Gateway running: `ss -ltnp | grep 18790`
- [ ] Memory indexed: `OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw memory status`

### Host Setup
- [ ] Host directories exist:
  - [ ] `ls ~/openclaw/zhuoyue/media/inbound/`
  - [ ] `ls ~/openclaw/zhuoyue/transcripts/`
  - [ ] `ls ~/openclaw/zhuoyue/workspace/`
- [ ] launchd running: `launchctl list | grep transcribe-zhuoyue`
- [ ] Google Drive folders exist: `ls ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/zhuoyue/`

### Transcript Watcher
- [ ] tmux session running: `tmux ls | grep transcript-watcher-zhuoyue`
- [ ] Environment variables set correctly (attach to tmux and check logs)

### End-to-End Tests

#### Test 1: Telegram Text Message
```bash
# Open Telegram, message Zhuoyue's bot:
Hello! This is a test.

# Expected: Bot responds immediately
# Check VM logs if no response:
tail -f /tmp/openclaw-gateway-zhuoyue.log
```

#### Test 2: Telegram Voice Memo
```bash
# Send a short voice message via Telegram (< 1 minute)
# Expected timeline:
# 1. Audio appears in ~/openclaw/zhuoyue/media/inbound/ (< 1 sec)
# 2. launchd triggers transcription (within 5-10 sec)
# 3. Transcript appears in ~/openclaw/zhuoyue/transcripts/ (~10-30 sec)
# 4. transcript-watcher processes it (< 1 sec)
# 5. Bot sends transcribed text back via Telegram (< 5 sec)

# Debug if it fails:
tail -f /tmp/transcribe-zhuoyue.log  # Host-side transcription
tmux attach -t transcript-watcher-zhuoyue  # VM-side processing
```

#### Test 3: Memory Search
```bash
# Add some content to MEMORY.md, then test search:
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw memory index --force
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw memory search "test"

# Or ask via Telegram:
# "What do you remember about my projects?"
```

---

## Notes

### Isolation Guarantees
- **No data sharing:** Zhuoyue's instance uses `~/.openclaw-zhuoyue` (VM) and `~/openclaw/zhuoyue/` (host) - completely separate from Xin's `~/.openclaw/` and `~/openclaw/xin/`
- **No session cross-contamination:** Each gateway runs independently with `session.dmScope: per-peer`
- **No memory overlap:** Agents have separate SQLite databases and workspace paths

### Important Environment Variables
- **`OPENCLAW_STATE_DIR`:** Required for all `openclaw` commands targeting Zhuoyue's instance
- **`TELEGRAM_CHAT_ID`:** Required by transcript-watcher to send messages back to Telegram

### After VM Reboot
You'll need to restart two processes:

```bash
# 1. Gateway
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue \
  nohup openclaw gateway run --bind loopback --port 18790 --force \
  > /tmp/openclaw-gateway-zhuoyue.log 2>&1 &

# 2. Transcript watcher
tmux new-session -d -s transcript-watcher-zhuoyue \
  "OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue TELEGRAM_CHAT_ID=YOUR_CHAT_ID /Volumes/My\ Shared\ Files/scripts/knowledge-base/zhuoyue/transcript-watcher.sh"
```

Configuration persists automatically - no need to reconfigure.

### Port Convention
- **Xin:** 18789
- **Zhuoyue:** 18790
- Each user has an isolated gateway on a unique port

### Placeholder Secrets
Replace these placeholders with actual values:
- `ZHUOYUE_BOT_TOKEN` - Get from [@BotFather](https://t.me/BotFather)
- `ZHUOYUE_USER_ID` - Get from [@userinfobot](https://t.me/userinfobot)
- `sk-...` - Moonshot API key from [Moonshot AI](https://platform.moonshot.cn/)

### Shared Components
Both users share:
- **mlx-audio installation** (host Mac)
- **Ollama installation** (host Mac)
- **Lume VM** (but separate state directories inside)
- **VirtioFS shared folder** (`~/openclaw/` - but isolated subdirectories)

Each user's launchd plist, transcribe.sh, and transcript-watcher.sh are separate with hardcoded paths.

---

## Troubleshooting

### Gateway Won't Start
```bash
# Check if port is already in use
ss -ltnp | grep 18790

# Check logs for errors
tail -n 100 /tmp/openclaw-gateway-zhuoyue.log

# Verify config is valid
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw config get agents.defaults.model
```

### Telegram Not Responding
```bash
# Check gateway is running
ss -ltnp | grep 18790

# Check bindings are correct
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw config get bindings

# Check allowlist includes your user ID
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw config get channels.telegram.allowlist

# Check gateway logs
tail -f /tmp/openclaw-gateway-zhuoyue.log
```

### Transcripts Not Processing
```bash
# Check transcript-watcher is running
tmux ls | grep transcript-watcher-zhuoyue

# View live logs
tmux attach -t transcript-watcher-zhuoyue

# Check transcripts folder accessible from VM
ls "/Volumes/My Shared Files/zhuoyue/transcripts/"

# Check host-side transcription is working
tail -f /tmp/transcribe-zhuoyue.log
ls ~/openclaw/zhuoyue/transcripts/

# Verify session memory is enabled
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw config get agents.defaults.memorySearch.experimental.sessionMemory
```

### Audio Not Transcribing
```bash
# Check launchd is loaded
launchctl list | grep transcribe-zhuoyue

# Check logs
tail -f /tmp/transcribe-zhuoyue.log

# Test mlx-audio manually
say "Test" -o /tmp/test.aiff
ffmpeg -y -i /tmp/test.aiff /tmp/test.mp3 2>/dev/null
python -m mlx_audio.stt.generate \
  --model mlx-community/VibeVoice-ASR-bf16 \
  --audio /tmp/test.mp3 \
  --format json

# Check if audio file is landing in the right place
ls ~/openclaw/zhuoyue/media/inbound/
```

### Memory Not Searchable
```bash
# Reindex
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw memory index --force --verbose

# Check status
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw memory status --deep

# Verify Ollama is accessible from VM
curl http://192.168.64.1:11434/api/tags
```

---

## Related Documentation

- [Personal Knowledge Base README](./README.md) - Architecture and concepts
- [Telegram Audio Flow](./telegram-audio-flow.md) - Technical flow documentation
- [Transcribe Flow](./transcribe-flow.md) - Host-side transcription details
- [Multi-User Setup](./README.md#multi-user-setup) - High-level multi-user overview
- [Migrating from Single-User](./README.md#migrating-from-single-user-setup) - Migration guide

---

## Summary

You've successfully set up Zhuoyue as a second user with:

1. **Isolated state:** `~/.openclaw-zhuoyue` (VM) and `~/openclaw/zhuoyue/` (host)
2. **Separate Telegram bot:** Routes messages to `zhuoyue` agent
3. **Independent gateway:** Port 18790
4. **Dedicated transcription pipeline:** launchd watches `~/openclaw/zhuoyue/media/inbound/`
5. **Isolated memory:** Separate workspace, transcripts, and database

Both Xin and Zhuoyue can use the system simultaneously without any interference. Each user has their own Telegram bot, agent, workspace, transcripts, and memory database.
