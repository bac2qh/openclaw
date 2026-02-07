# Telegram Audio Flow Documentation

This document explains how audio flows from Telegram through the OpenClaw system, covering both the built-in sync transcription and the local async transcription approaches.

## Overview

OpenClaw supports two distinct audio processing flows:

1. **Flow A: Built-in Sync Transcription** (Default) - Cloud-based, immediate response
2. **Flow B: Local Async Transcription** (README approach) - Local processing, delayed response

## Flow A: Built-in Sync Transcription (Default)

This is the standard OpenClaw flow using cloud transcription APIs.

### Architecture

```
Telegram Voice Message
         │
         ▼
┌─────────────────────────────────┐
│  1. RECEIVE & DOWNLOAD          │
│  bot-handlers.ts:655            │
│  → resolveMedia()               │
│  → saveMediaBuffer()            │
│  → ~/.openclaw/media/inbound/   │
└─────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  2. TRANSCRIBE (Cloud API)      │
│  media-understanding/apply.ts   │
│  → runCapability("audio")       │
│  → OpenAI/Deepgram/Groq         │
│  → ctx.Transcript = "text"      │
└─────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  3. AI RESPONSE                 │
│  → Claude generates reply       │
│  → Uses transcript as input     │
│  → ctx.Body = transcript text   │
└─────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  4. DELIVER TO TELEGRAM         │
│  → bot.api.sendMessage()        │
│  → User receives AI response    │
└─────────────────────────────────┘
```

### Key Files

| File | Line | Purpose |
|------|------|---------|
| `src/telegram/bot-handlers.ts` | 655 | Message handler entry point |
| `src/telegram/bot/delivery.ts` | 294 | `resolveMedia()` - downloads file |
| `src/media/store.ts` | 211 | `saveMediaBuffer()` - saves to disk |
| `src/media-understanding/apply.ts` | 454 | Triggers media understanding |
| `src/media-understanding/runner.ts` | 1158 | `runCapability()` - provider selection |

### Configuration

```bash
# Enable audio transcription (default)
openclaw config set tools.media.audio.enabled true

# Configure provider (OpenAI, Deepgram, or Groq)
openclaw config set tools.media.audio.models '[{"provider":"openai","model":"whisper-1"}]'
```

### Data Flow

1. **Download**: Voice message → `~/.openclaw/media/inbound/voice-{uuid}.ogg`
2. **Transcribe**: File sent to cloud API → returns transcript text
3. **Context**: Transcript stored in `ctx.Transcript` and `ctx.Body`
4. **AI Response**: Claude sees transcript as user message and responds
5. **Cleanup**: Media files cleaned up after 2 minutes (TTL)

### When to Use

- ✅ Short voice messages (< 5 minutes)
- ✅ Need immediate AI response
- ✅ Okay with cloud transcription costs
- ✅ Want conversation context integration

### Cost

- ~$0.006 per minute (OpenAI Whisper)
- ~$0.0043 per minute (Deepgram Nova-2)

---

## Flow B: Local Async Transcription (README Approach)

This approach uses local mlx-audio transcription with a 2-watcher async pipeline.

### Architecture

```
Telegram Voice Message
         │
         ▼
┌─────────────────────────────────┐
│  1. DOWNLOAD TO VM              │
│  bot-handlers.ts:655            │
│  → resolveMedia()               │
│  → ~/.openclaw/media/inbound/   │
│  (NOT configurable currently)   │
└─────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  2. TRANSCRIPTION DISABLED      │
│  tools.media.audio.enabled=false│
│  → No cloud transcription       │
│  → ctx.Transcript = undefined   │
│  → ctx.Body = "<media:audio>"   │
└─────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  3. HOST TRANSCRIBES LOCALLY    │
│  (MANUAL COPY REQUIRED)         │
│  → Copy from VM to host folder  │
│  → launchd → transcribe.sh      │
│  → mlx-audio (VibeVoice-ASR)    │
│  → ~/openclaw/transcripts/*.json│
└─────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  4. AI PROCESSES TRANSCRIPT     │
│  → openclaw agent --message     │
│  → Summarizes meeting           │
│  → Extracts action items        │
│  → Updates memory/knowledge     │
└─────────────────────────────────┘
```

### Key Limitations

⚠️ **CRITICAL GAPS IDENTIFIED**: The README's approach has key limitations:

1. **Config doesn't exist**: `tools.media.downloadPath` is NOT implemented in the codebase
2. **Files land in VM only**: Audio always downloads to `~/.openclaw/media/inbound/` (inside VM)
3. **Manual copy required**: Files don't automatically land in the shared folder
4. **AI processing vs notification**: Use `openclaw agent` for processing, not `openclaw message send` for delivery

### Configuration (as documented in README)

```bash
# Disable cloud transcription
openclaw config set tools.media.audio.enabled false

# ❌ This config does NOT exist in the codebase!
# openclaw config set tools.media.downloadPath "/Volumes/My Shared Files/media/recordings"
```

### What Actually Happens

1. **Download**: Voice message → `~/.openclaw/media/inbound/voice-{uuid}.ogg` (inside VM)
2. **No Transcription**: `tools.media.audio.enabled=false` skips cloud API
3. **AI Response**: Claude sees `<media:audio>` placeholder (no transcript)
4. **Manual Step**: User must copy file from VM to host shared folder
5. **Host Transcription**: launchd watches shared folder → mlx-audio → transcript JSON
6. **Watcher 2**: Triggers AI processing via `openclaw agent --message`
7. **Result**: AI processes transcript, extracts insights, updates memory

### When to Use

- ✅ Very long recordings (> 1 hour)
- ✅ Okay with async/delayed transcription
- ✅ Want 100% local transcription (privacy)
- ✅ Have Apple Silicon Mac (M1/M2/M3)
- ⚠️ Willing to manually copy files or script the copy step
- ⚠️ Don't need immediate AI response

### Cost

- **FREE** - 100% local transcription via mlx-audio

---

## Comparison Table

| Feature | Flow A (Sync) | Flow B (Async) |
|---------|--------------|----------------|
| **Transcription** | Cloud API | Local mlx-audio |
| **Response time** | Immediate (< 10s) | Delayed (minutes to hours) |
| **Context integration** | ✅ Yes - part of conversation | ⚠️ Processed async via agent |
| **Cost** | ~$0.006/min | FREE |
| **Privacy** | Cloud | 100% local |
| **Configuration** | Works out of box | ⚠️ Requires workaround |
| **Best for** | Short voice memos | Long recordings (> 1 hour) |
| **AI sees transcript** | ✅ Yes - in `ctx.Transcript` | ✅ Yes - via agent processing |

---

## Gap Analysis: README vs Reality

### What the README Claims

> "Point OpenClaw to save Telegram voice messages to the shared recordings folder"
> ```bash
> openclaw config set tools.media.downloadPath "/Volumes/My Shared Files/media/recordings"
> ```

### The Reality

1. **Config doesn't exist**: `tools.media.downloadPath` is NOT found in:
   - `src/config/types.tools.ts` (MediaToolsConfig)
   - Any TypeScript source files
   - Git history shows it was documented but never implemented

2. **Hardcoded path**: Media is always saved to:
   ```typescript
   // src/media/store.ts:221
   const dir = path.join(resolveMediaDir(), subdir);
   // resolveMediaDir() returns ~/.openclaw/media/
   ```

3. **Subdir is hardcoded**: `saveMediaBuffer()` is called with `subdir="inbound"`
   ```typescript
   // src/telegram/bot/delivery.ts:418-424
   const saved = await saveMediaBuffer(
     fetched.buffer,
     fetched.contentType,
     "inbound",  // ← hardcoded
     maxBytes,
     originalName,
   );
   ```

### Important: Agent Processing vs Message Delivery

| Command | Behavior | Use Case |
|---------|----------|----------|
| `openclaw message send` | Just delivers text - AI doesn't process it | Simple notifications |
| `openclaw agent --message` | **Triggers full AI processing** - reads, thinks, updates memory | Transcript analysis |

**Recommendation:** Always use `openclaw agent --message` for transcripts so the AI actually processes them (summarizes, extracts action items, updates memory) instead of just delivering raw text.

### Workaround Options

#### Option 1: Symlink (Simplest)

```bash
# Inside VM
mv ~/.openclaw/media/inbound ~/.openclaw/media/inbound.backup
ln -s "/Volumes/My Shared Files/media/recordings" ~/.openclaw/media/inbound

# Now files download directly to shared folder
```

**Pros**: No code changes, works immediately
**Cons**: All inbound media goes to shared folder (not just audio)

#### Option 2: Manual Copy Script (README approach)

```bash
# Inside VM - watch and copy script
#!/bin/bash
fswatch -0 ~/.openclaw/media/inbound/ | while read -d "" file; do
  if [[ "$file" == *.ogg ]] || [[ "$file" == *.mp3 ]]; then
    cp "$file" "/Volumes/My Shared Files/media/recordings/"
  fi
done
```

**Pros**: Selective copying (audio only)
**Cons**: Extra process, potential race conditions

#### Option 3: Implement downloadPath Config (Future Enhancement)

Modify the codebase to support `tools.media.downloadPath`:

```typescript
// src/media/store.ts
const resolveMediaDir = (cfg?: OpenClawConfig) => {
  const customPath = cfg?.tools?.media?.downloadPath;
  if (customPath) return customPath;
  return path.join(resolveConfigDir(), "media");
};
```

**Pros**: Proper solution, matches README
**Cons**: Requires code changes, needs PR

---

## Recommendations

### For Short Voice Messages (< 5 minutes)

**Use Flow A (Default Sync)**

```bash
# Enable cloud transcription
openclaw config set tools.media.audio.enabled true

# Configure provider
openclaw config set tools.media.audio.models '[{"provider":"openai","model":"whisper-1"}]'
```

**Why**: Immediate response, conversation context integration, low cost

### For Long Recordings (> 1 hour)

**Use Flow B with Workaround**

```bash
# Inside VM: Symlink inbound to shared folder
mv ~/.openclaw/media/inbound ~/.openclaw/media/inbound.backup
ln -s "/Volumes/My Shared Files/media/recordings" ~/.openclaw/media/inbound

# Disable cloud transcription
openclaw config set tools.media.audio.enabled false

# Host: Setup mlx-audio transcription (see README Part 1)
```

**Why**: Free local transcription, good for multi-hour meetings

### Hybrid Approach (Recommended)

Use both flows based on message length:

1. **Default**: Flow A enabled for < 5 minute voice messages
2. **Manual**: For long recordings, manually upload to host folder
3. **Async pipeline**: Watcher 2 sends transcripts back when ready

---

## Testing Both Flows

### Test Flow A (Sync)

```bash
# 1. Enable cloud transcription
openclaw config set tools.media.audio.enabled true
openclaw config set tools.media.audio.models '[{"provider":"openai","model":"whisper-1"}]'

# 2. Send voice message to Telegram bot
# 3. Expect: Immediate AI response with transcribed text
```

### Test Flow B (Async with Workaround)

```bash
# 1. Setup symlink (inside VM)
ln -s "/Volumes/My Shared Files/media/recordings" ~/.openclaw/media/inbound

# 2. Disable cloud transcription
openclaw config set tools.media.audio.enabled false

# 3. Verify host transcription setup (on host Mac)
ls ~/openclaw/media/recordings/
tail -f /tmp/transcribe.log

# 4. Start Watcher 2 (inside VM)
export TELEGRAM_CHAT_ID="YOUR_CHAT_ID"
~/transcript-watcher.sh

# 5. Send voice message to Telegram bot
# 6. Expect: Transcript arrives as separate message later
```

---

## Future Enhancements

1. **Implement `tools.media.downloadPath` config** - Make README accurate
2. **Add `tools.media.audio.downloadPath`** - Audio-specific path override
3. **Integrate async transcripts** - Send to same conversation thread
4. **Smart routing** - Auto-detect long audio, route to async pipeline
5. **Status updates** - Send "Transcribing..." status to user

---

## Related Files

| File | Purpose |
|------|---------|
| `docs/guides/personal-knowledge-base/README.md` | Main guide (describes Flow B) |
| `scripts/knowledge-base/transcribe.sh` | Host-side mlx-audio transcription |
| `scripts/knowledge-base/transcript-watcher.sh` | Watcher 2 (sends transcripts) |
| `src/telegram/bot-handlers.ts` | Telegram message handler |
| `src/media/store.ts` | Media file storage |
| `src/media-understanding/runner.ts` | Cloud transcription logic |

---

## Support

For issues or questions:
- GitHub: https://github.com/openclaw/openclaw/issues
- Docs: https://docs.openclaw.ai/

