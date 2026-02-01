# Quick Start: Personal Memory Bot

Get a voice-powered memory bot running in 10 minutes with OpenClaw, Telegram, and Claude Sonnet 4.

## Prerequisites

- Node.js 22+
- Anthropic API key (get at https://console.anthropic.com/)
- Telegram account

## Installation

```bash
# Install OpenClaw
npm install -g openclaw@latest

# Initialize config
openclaw config init
```

## Configuration

```bash
# Set Claude Sonnet 4
openclaw config set agents.defaults.model "claude-sonnet-4-20250514"
openclaw config set providers.anthropic.apiKey "sk-ant-..."

# Enable memory search with OpenAI embeddings
openclaw config set agents.defaults.memorySearch.enabled true
openclaw config set agents.defaults.memorySearch.provider "openai"
openclaw config set providers.openai.apiKey "sk-..."

# Configure Telegram bot
# 1. Create bot via @BotFather on Telegram
# 2. Get your user ID from @userinfobot
openclaw config set channels.telegram.botToken "YOUR_BOT_TOKEN"
openclaw config set channels.telegram.allowFrom '["YOUR_TELEGRAM_USER_ID"]'

# Enable voice transcription (uses OpenAI Whisper by default)
openclaw config set tools.media.audio.enabled true
```

## Create Memory Workspace

```bash
mkdir -p ~/.openclaw/workspace/memory

cat > ~/.openclaw/workspace/MEMORY.md << 'EOF'
# My Memory

## About Me
- Name: [Your Name]

## Preferences
- [Add preferences]

## Important Info
- [Add key information]
EOF
```

## Start Gateway

```bash
# Start in foreground (see logs)
openclaw gateway run

# Or background
nohup openclaw gateway run > ~/openclaw-gateway.log 2>&1 &
```

## Test It

1. Open Telegram → your bot
2. Send: "Hello!"
3. Approve pairing if prompted
4. Send a voice message: "Testing voice transcription"
5. Bot should transcribe and respond

## Usage

### Voice Memos
- Hold mic button in Telegram → speak → release
- "Remember that Alice prefers async communication"
- "Note: deadline is March 15th"

### Query Memory
- "What did I say about Alice?"
- "What's the deadline?"
- "Summarize my notes from this week"

### Reminders
- "Remind me in 30 minutes to check email"
- "Remind me every day at 5pm to review tasks"
- "List my reminders"

## What You Get

- **Voice memos**: Automatically transcribed and stored
- **Memory search**: Semantic search across all notes
- **Meeting transcription**: Send audio files, get transcripts
- **Reminders**: Natural language scheduling
- **Daily notes**: Automatic journaling in `memory/YYYY-MM-DD.md`
- **Long-term memory**: Curated facts in `MEMORY.md`

## Cost Estimate

- Claude Sonnet 4 API: ~$6/month
- OpenAI (embeddings + transcription): ~$15/month
- **Total: ~$21/month**

To reduce costs:
- Use Groq for transcription (free tier)
- Use Gemini for embeddings ($0.10/month)
- Use WhisperX for transcription (local, free)

## Next Steps

- Read the full guide: `docs/guides/personal-knowledge-base.md`
- Configure Deepgram for better transcription: https://console.deepgram.com/
- Set up WhisperX for local transcription (no API costs)
- Explore OpenClaw skills: `openclaw skills list`

## Troubleshooting

**Bot not responding?**
```bash
openclaw channels status  # Check if Telegram is connected
tail -f ~/openclaw-gateway.log  # View logs
```

**Voice not transcribing?**
```bash
openclaw config get tools.media.audio  # Check config
```

**Memory search not working?**
```bash
openclaw memory status  # Check index status
openclaw memory index --force  # Force reindex
```

## Support

- Issues: https://github.com/openclaw/openclaw/issues
- Docs: https://docs.openclaw.ai/
- Full guide: `docs/guides/personal-knowledge-base.md`

---

**You're ready! Start recording your thoughts and memories. 🧠**
