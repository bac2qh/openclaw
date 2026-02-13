# Transcribe Pipeline Flow

This document explains the `transcribe.sh` pipeline that processes audio files using local mlx-audio transcription. It covers format conversion, duration-based routing, model selection, chunking for long recordings, transcription, cleanup, and downstream consumption.

## Overview

The transcribe pipeline runs on the host Mac (not in VM) and monitors `~/openclaw/media/inbound/` for new audio files. It:

1. Converts OGG/M4A → MP3 (miniaudio compatibility)
2. Detects audio duration
3. Selects optimal model based on duration
4. Splits long recordings into overlapping chunks
5. Transcribes with mlx-audio (Microsoft VibeVoice-ASR)
6. Cleans up temporary files
7. Syncs transcripts to Google Drive
8. Triggers downstream watcher for Telegram delivery

**Key Feature**: 100% local, FREE transcription for unlimited duration audio.

---

## Scenario Walkthrough: 90-Minute M4A File

Let's trace what happens when a 90-minute Telegram voice message lands in the input folder.

```
~/openclaw/media/inbound/voice-abc123.m4a (90 minutes)
         │
         ▼
┌────────────────────────────────────────┐
│  STEP 1: FORMAT CONVERSION             │
│  transcribe.sh:122-135                 │
│  → ffmpeg converts M4A to MP3          │
│  → voice-abc123.mp3 created            │
│  → Original M4A kept for now           │
└────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────┐
│  STEP 2: DURATION DETECTION            │
│  transcribe.sh:137-145                 │
│  → ffprobe reads MP3 metadata          │
│  → Duration: 5400 seconds (90 min)     │
│  → duration=5400                       │
└────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────┐
│  STEP 3: MODEL SELECTION               │
│  transcribe.sh:147-154                 │
│  → duration (5400s) > MODEL_THRESHOLD  │
│  →   (600s = 10 min)                   │
│  → Selected: VibeVoice-ASR-bf16        │
│  →   (includes speaker diarization)    │
└────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────┐
│  STEP 4: CHUNKING DECISION             │
│  transcribe.sh:156-168                 │
│  → duration (5400s) > CHUNK_THRESHOLD  │
│  →   (3300s = 55 min)                  │
│  → YES: Split into chunks              │
│  → Chunk size: 55 min (3300s)          │
│  → Chunk step: 50 min (3000s)          │
│  → Overlap: 5 minutes                  │
└────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────┐
│  STEP 5: CHUNK CREATION                │
│  transcribe.sh:64-94                   │
│  → Chunk 1: 0s to 3300s (0-55 min)     │
│  →   voice-abc123_part1.mp3            │
│  → Chunk 2: 3000s to 6300s (50-105m)   │
│  →   voice-abc123_part2.mp3            │
│  →   (overlaps with chunk 1 at 50-55m) │
│  → Total: 2 chunks created             │
└────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────┐
│  STEP 6: TRANSCRIPTION (CHUNK 1)       │
│  transcribe.sh:176-189                 │
│  → mlx-audio transcribes part1.mp3     │
│  → Model: VibeVoice-ASR-bf16           │
│  → Output: 2025-02-13-1430-            │
│  →   voice-abc123_part1.json           │
│  → Contains: text, timestamps,         │
│  →   speaker labels                    │
└────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────┐
│  STEP 7: TRANSCRIPTION (CHUNK 2)       │
│  transcribe.sh:176-189                 │
│  → mlx-audio transcribes part2.mp3     │
│  → Model: VibeVoice-ASR-bf16           │
│  → Output: 2025-02-13-1430-            │
│  →   voice-abc123_part2.json           │
│  → Contains: text, timestamps,         │
│  →   speaker labels                    │
└────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────┐
│  STEP 8: CLEANUP                       │
│  transcribe.sh:193-215                 │
│  → Delete voice-abc123_part1.mp3       │
│  → Delete voice-abc123_part2.mp3       │
│  → Delete voice-abc123.mp3 (converted) │
│  → Move voice-abc123.m4a to NAS        │
│  →   /Volumes/NAS_1/.../recordings/    │
└────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────┐
│  STEP 9: GOOGLE DRIVE SYNC             │
│  transcribe.sh:252-273                 │
│  → rsync ~/openclaw/transcripts/       │
│  →   to Google Drive                   │
│  → Both JSON files now in cloud        │
│  → Accessible from VM                  │
└────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────┐
│  STEP 10: WATCHER CONSUMPTION          │
│  transcript-watcher.sh (separate)      │
│  → Watches for new JSON files          │
│  → Sends to Telegram via openclaw      │
│  → User receives 2 messages:           │
│  →   Part 1: 0-55 min transcript       │
│  →   Part 2: 50-90 min transcript      │
└────────────────────────────────────────┘
```

**Result**: A 90-minute recording is transcribed into 2 overlapping chunks, each with speaker labels and timestamps, synced to cloud, and delivered back to Telegram as separate messages.

---

## Overlap Visualization

For long recordings, chunks overlap by 5 minutes to ensure no content is lost at boundaries.

```
Recording Timeline (90 minutes):
0m        10m       20m       30m       40m       50m       60m       70m       80m       90m
├─────────┼─────────┼─────────┼─────────┼─────────┼─────────┼─────────┼─────────┼─────────┤
│                                                                                           │
├───────────────────────────────────────────────────┤  Chunk 1 (0-55 min)
                                        ├───────────────────────────────────────────────────┤  Chunk 2 (50-90 min)
                                        └──5 min overlap──┘

Key Points:
- Chunk 1: Transcribes 0:00 to 55:00
- Chunk 2: Transcribes 50:00 to 90:00 (or end of file)
- Overlap: Both chunks include 50:00 to 55:00
- Benefit: Ensures no missed words during transitions
- Note: User sees some duplicate content in overlap region
```

---

## Configuration Thresholds

These constants control model selection and chunking behavior:

| Threshold | Value | Description | Impact |
|-----------|-------|-------------|--------|
| `MODEL_THRESHOLD` | 600s (10 min) | Model selection cutoff | < 10 min: whisper-turbo<br>> 10 min: VibeVoice-ASR |
| `CHUNK_THRESHOLD` | 3300s (55 min) | Chunking trigger | < 55 min: single transcription<br>> 55 min: split into chunks |
| `CHUNK_DURATION` | 3300s (55 min) | Length of each chunk | Each chunk is 55 minutes |
| `CHUNK_STEP` | 3000s (50 min) | Start time increment | 5-minute overlap between chunks |
| `MAX_TOKENS` | 65536 | mlx-audio token limit | Prevents OOM on M1/M2 Macs |
| `HOTWORDS_FILE` | `~/openclaw/config/hotwords.txt` | Context terms for VibeVoice-ASR | Optional file with domain-specific terms (one per line) |

**Rationale**:
- **10-minute threshold**: Whisper-turbo is 3x faster for short audio; VibeVoice-ASR provides better accuracy + diarization for longer content
- **55-minute chunks**: Balances memory usage (mlx-audio on Apple Silicon) with processing efficiency
- **5-minute overlap**: Safety margin to avoid losing content at chunk boundaries
- **Hotwords context**: VibeVoice-ASR only (> 10 min recordings). Improves recognition of proper nouns, technical terms, and project-specific vocabulary

---

## Hotwords Configuration

### What Are Hotwords?

Hotwords are domain-specific terms that bias the transcription model toward recognizing specific vocabulary. The VibeVoice-ASR model supports a `--context` flag that accepts a comma-separated list of terms to improve accuracy for proper nouns, technical terms, and project-specific vocabulary.

### File Format

```
~/openclaw/config/hotwords.txt
```

One term per line (blank lines and comments ignored):
```
OpenClaw
VibeVoice
MLX
Apple Silicon
Claude Sonnet
```

This is converted to: `"OpenClaw,VibeVoice,MLX,Apple Silicon,Claude Sonnet"` and passed as `--context` to mlx-audio.

### When Are Hotwords Used?

- **VibeVoice-ASR only**: Hotwords are passed to recordings > 10 minutes (long recordings that use the full model)
- **Whisper-turbo**: Hotwords are NOT used for short recordings (< 10 minutes)
- **Optional**: Missing or empty hotwords file means no context is passed (backward compatible)

### Agent-Driven Updates

The hotwords file is located in the shared folder, so it can be updated by the Telegram agent before a meeting:

| Side | Path | Notes |
|------|------|-------|
| **Host Mac** | `~/openclaw/config/hotwords.txt` | Read by `transcribe.sh` |
| **VM** | `/Volumes/My Shared Files/config/hotwords.txt` | Written by agent via exec/write tool |

**Workflow:**
1. Before a meeting, tell the Telegram agent: "Update hotwords for my next meeting: Alice, Bob, ProjectX"
2. Agent writes to `/Volumes/My Shared Files/config/hotwords.txt` (VM path)
3. File is immediately visible on host at `~/openclaw/config/hotwords.txt` (same file via VirtioFS)
4. Next recording uses the updated hotwords automatically

**No polling delay**: VirtioFS provides bidirectional, immediate file visibility. Changes are effective on the next transcription run.

### Setup

**Create the hotwords file:**

```bash
# Copy the example file
cp scripts/knowledge-base/hotwords-example.txt ~/openclaw/config/hotwords.txt

# Edit to add your terms
nano ~/openclaw/config/hotwords.txt
```

**Example hotwords file:**

See `scripts/knowledge-base/hotwords-example.txt` for a documented example.

### Verification

**Test hotwords are being used:**

```bash
# Create test audio with a hotword term
say "Testing OpenClaw transcription with hotwords" -o ~/openclaw/media/inbound/test-hotwords.m4a

# Run transcription
~/openclaw/scripts/transcribe.sh

# Check log output (should show "Context: OpenClaw,...")
tail -f /tmp/transcribe.log
```

**Expected log output for > 10 min recordings:**
```
[2026-02-13 14:30:00] Processing: test-hotwords.m4a
[2026-02-13 14:30:01]   Duration: 65 minutes (3900s)
[2026-02-13 14:30:01]   Model: VibeVoice-ASR (long recording)
[2026-02-13 14:30:01]   Context: OpenClaw,VibeVoice,MLX,Apple Silicon
```

**Expected log output for < 10 min recordings:**
```
[2026-02-13 14:30:00] Processing: short-voice.m4a
[2026-02-13 14:30:01]   Duration: 5 minutes (300s)
[2026-02-13 14:30:01]   Model: whisper-turbo (short recording)
```
(No "Context:" line appears for short recordings)

---

## File Lifecycle

### Input Files (What Arrives)

| File | Source | Format | Location |
|------|--------|--------|----------|
| `voice-{uuid}.ogg` | Telegram voice message | OGG Vorbis | `~/openclaw/media/inbound/` |
| `voice-{uuid}.m4a` | Telegram audio/recording | M4A AAC | `~/openclaw/media/inbound/` |

### Intermediate Files (Temporary)

| File | Purpose | Lifecycle | Location |
|------|---------|-----------|----------|
| `voice-{uuid}.mp3` | Converted for mlx-audio | Created → Deleted after transcription | `~/openclaw/media/inbound/` |
| `voice-{uuid}_part1.mp3` | Chunk 1 audio | Created → Deleted after transcription | `~/openclaw/media/inbound/` |
| `voice-{uuid}_part2.mp3` | Chunk 2 audio | Created → Deleted after transcription | `~/openclaw/media/inbound/` |
| `voice-{uuid}_partN.mp3` | Chunk N audio | Created → Deleted after transcription | `~/openclaw/media/inbound/` |

### Output Files (Permanent)

| File | Content | Lifecycle | Location |
|------|---------|-----------|----------|
| `{timestamp}-{name}.json` | Single-file transcript | Permanent (synced to cloud) | `~/openclaw/transcripts/` |
| `{timestamp}-{name}_part1.json` | Chunk 1 transcript | Permanent (synced to cloud) | `~/openclaw/transcripts/` |
| `{timestamp}-{name}_part2.json` | Chunk 2 transcript | Permanent (synced to cloud) | `~/openclaw/transcripts/` |

### Archive Files (Original Audio)

| File | Destination | Condition |
|------|-------------|-----------|
| `voice-{uuid}.ogg` | `/Volumes/NAS_1/Xin/openclaw/media/recordings/` | If NAS mounted |
| `voice-{uuid}.m4a` | `/Volumes/NAS_1/Xin/openclaw/media/recordings/` | If NAS mounted |
| (same) | `~/openclaw/media/inbound/` | If NAS NOT mounted (kept locally) |

**Key Insight**: Only the original audio files are archived. Converted MP3s and chunk files are always deleted to save space.

---

## Edge Cases

### Exactly 55 Minutes

```
Duration: 3300s (exactly 55 minutes)

Behavior:
- duration (3300) > CHUNK_THRESHOLD (3300)  → FALSE (not greater)
- No chunking occurs
- Transcribed as single file
- Model: VibeVoice-ASR-bf16 (exceeds 10-minute threshold)
```

### Between 10-55 Minutes

```
Duration: 1800s (30 minutes)

Behavior:
- Model: VibeVoice-ASR-bf16 (> 10 min)
- No chunking (< 55 min)
- Single transcription with speaker diarization
- Optimal case: Full model, no chunking overhead
```

### NAS Unmounted

```
Scenario: NAS drive /Volumes/NAS_1 not available

Behavior:
- Transcription proceeds normally
- Cleanup: Converted MP3s deleted
- Archive: Original M4A/OGG kept in ~/openclaw/media/inbound/
- Warning logged: "⚠ NAS not mounted, keeping files locally"
- User must manually move files to NAS later
```

### Google Drive Not Synced

```
Scenario: Insync not running or Google Drive unmounted

Behavior:
- Transcription proceeds normally
- Transcripts stay in ~/openclaw/transcripts/
- Warning logged: "⚠ Google Drive not available, skipping cloud sync"
- Watcher may not see new transcripts if it reads from GDrive path
- Fix: Run rsync manually or restart Insync
```

### Transcription Failure Mid-Chunk

```
Scenario: Chunk 1 succeeds, Chunk 2 fails (OOM, model error, etc.)

Behavior:
- Chunk 1 JSON created and saved
- Chunk 2 fails → error logged
- Cleanup skipped: All files kept for debugging
- Original M4A NOT moved to NAS
- User sees: "Some chunks failed to transcribe, keeping all files"
- Action: Check logs, re-run manually, or reduce CHUNK_DURATION
```

### Short Audio (< 10 Minutes)

```
Duration: 300s (5 minutes)

Behavior:
- Model: whisper-large-v3-turbo-asr-fp16 (fast model)
- No chunking
- No speaker diarization (Whisper doesn't support it)
- 3x faster than VibeVoice-ASR
- Trade-off: Speed over accuracy/features
```

---

## Related Files

| File | Purpose | Key Functions |
|------|---------|---------------|
| `scripts/knowledge-base/transcribe.sh` | Main transcription pipeline | `get_audio_duration()`, `split_audio_into_chunks()` |
| `scripts/knowledge-base/transcript-watcher.sh` | Watches for new transcripts, sends to Telegram | File monitoring, `openclaw agent --message` |
| `docs/guides/personal-knowledge-base/README.md` | Setup guide for local transcription | Installation, launchd config |
| `docs/guides/personal-knowledge-base/telegram-audio-flow.md` | Comparison: cloud vs local transcription | Flow A (sync) vs Flow B (async) |
| `src/telegram/bot-handlers.ts` | Telegram message handler (cloud transcription) | `resolveMedia()`, message routing |
| `src/media-understanding/runner.ts` | Cloud transcription logic | OpenAI/Deepgram/Groq provider selection |

---

## Dependencies

### Required

| Tool | Version | Purpose | Install |
|------|---------|---------|---------|
| `mlx-audio` | Latest | Apple Silicon audio transcription | `pip install mlx-audio` |
| `ffmpeg` | Latest | Audio conversion, duration detection | `brew install ffmpeg` |
| `ffprobe` | (included) | Audio metadata extraction | Bundled with ffmpeg |

### Optional

| Tool | Purpose | Fallback Behavior |
|------|---------|-------------------|
| Insync (Google Drive) | Cloud sync for transcripts | Transcripts stay local-only |
| NAS mount (`/Volumes/NAS_1`) | Audio archival | Original files kept in `~/openclaw/media/inbound/` |

---

## Performance Characteristics

### Model Speed Comparison

| Model | Duration | Transcription Time | Speed Ratio | Diarization |
|-------|----------|-------------------|-------------|-------------|
| whisper-turbo | 5 min | ~30 sec | 10x realtime | ❌ No |
| VibeVoice-ASR | 5 min | ~90 sec | 3.3x realtime | ✅ Yes |
| whisper-turbo | 60 min | ~6 min | 10x realtime | ❌ No |
| VibeVoice-ASR | 60 min (as 2 chunks) | ~36 min | 3.3x realtime | ✅ Yes |

**Hardware**: Apple Silicon M1/M2/M3 (tested on M2 Max)

### Memory Usage

| Scenario | Peak RAM | Notes |
|----------|----------|-------|
| Short audio (< 10 min) | ~4 GB | Whisper-turbo is lightweight |
| Long audio (55 min chunk) | ~12 GB | VibeVoice-ASR with diarization |
| Multiple concurrent chunks | ⚠️ Risk | Run sequentially, not in parallel |

**Recommendation**: Ensure at least 16 GB RAM for comfortable transcription of long recordings.

---

## Cost Comparison

| Approach | Cost | Privacy | Speed | Best For |
|----------|------|---------|-------|----------|
| **Cloud (OpenAI Whisper)** | $0.006/min | Cloud | Immediate | Short messages (< 5 min) |
| **Cloud (Deepgram Nova-2)** | $0.0043/min | Cloud | Immediate | Short messages (< 5 min) |
| **Local (transcribe.sh)** | **FREE** | 100% local | Async (minutes) | Long recordings (> 1 hour) |

**Example**: A 90-minute recording costs:
- OpenAI Whisper: $0.54
- Deepgram Nova-2: $0.39
- Local mlx-audio: **$0.00**

---

## Monitoring and Debugging

### Log Locations

```bash
# launchd stderr (if running as daemon)
tail -f ~/Library/Logs/com.user.transcribe-audio.err.log

# Script execution log (timestamps all output)
tail -f /tmp/transcribe.log

# Google Drive sync status
ls -lh ~/Insync/bac2qh@gmail.com/Google\ Drive/openclaw/transcripts/
```

### Common Issues

| Issue | Symptom | Fix |
|-------|---------|-----|
| "mlx-audio not found" | ImportError on script run | `pip install mlx-audio` in venv |
| "ffmpeg not found" | Command not found error | `brew install ffmpeg` |
| Transcription hangs | Script runs forever | Check RAM usage, reduce `CHUNK_DURATION` |
| Chunk files not cleaned | Disk space grows | Check script logs for transcription failures |
| NAS files not moved | Files stay in inbound folder | Verify NAS mounted at `/Volumes/NAS_1` |
| Watcher not triggered | No Telegram delivery | Check `transcript-watcher.sh` is running |

---

## Future Enhancements

1. **Real-time Progress Updates**: Send "Transcribing chunk 1/3..." status to Telegram
2. **Automatic Chunk Merging**: Combine overlapping chunks into single transcript
3. **GPU Acceleration**: Leverage Apple Neural Engine for faster transcription
4. **Configurable Models**: Allow per-user model selection (speed vs accuracy)
5. **Failure Recovery**: Auto-retry failed chunks with smaller duration
6. **Parallel Chunking**: Transcribe multiple chunks concurrently (if RAM allows)

---

## Support

For issues or questions:
- GitHub Issues: https://github.com/openclaw/openclaw/issues
- Documentation: https://docs.openclaw.ai/
