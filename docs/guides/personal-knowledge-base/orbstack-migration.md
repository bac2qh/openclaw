# Migrate from Lume VM to OrbStack Ubuntu

Migrate your OpenClaw gateway from a Lume VM (Apple Virtualization framework) to an OrbStack Ubuntu machine. OrbStack provides native Linux systemd support, seamless Mac filesystem access, and simpler networking — no VirtioFS quirks.

## What Changes

| Component | Lume (old) | OrbStack (new) |
|-----------|------------|-----------------|
| VM create | `lume create --os ubuntu` | `orb create ubuntu openclaw` |
| VM shell | `lume ssh nix` | `orb shell openclaw` |
| VM start/stop | `lume start/stop nix` | `orb start/stop openclaw` |
| Shared files mount | `/Volumes/My Shared Files/` | `/Users/xin.ding/` (direct) |
| Host IP from VM | `192.168.64.1` | `host.orbstack.internal` |
| Gateway management | `nohup openclaw gateway run &` | `openclaw gateway install` (systemd) |
| Transcript watcher | tmux session | systemd user service |

## What Stays the Same

- Host-side processes: mlx-audio (launchd), Ollama, rsync/sync, NAS archival
- Directory structure on Mac: `~/openclaw/xin/` and `~/openclaw/zhuoyue/`
- OpenClaw config keys and values (providers, channels, agents, browser settings)
- Port convention: xin → 18789, zhuoyue → 18790

---

## Step 1: Create the OrbStack Machine

Install OrbStack from [orbstack.dev](https://orbstack.dev) if not already installed, then:

```bash
# Create Ubuntu machine named "openclaw"
orb create ubuntu openclaw

# Shell into it
orb shell openclaw
```

Verify the Mac filesystem is accessible:

```bash
# Inside OrbStack
ls /Users/xin.ding/openclaw/xin/
```

You should see `media/`, `transcripts/`, `workspace/`, and `config/` — no mount or VirtioFS setup needed.

---

## Step 2: Install OpenClaw

```bash
# Install Node.js 22+
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs xvfb

# Install OpenClaw globally
npm install -g openclaw@latest

# Verify
openclaw --version
```

---

## Step 3: Transfer State from Lume VM

**Option A: Copy state from Lume VM**

```bash
# On Lume VM — create archive
tar czf /tmp/openclaw-state.tar.gz -C ~ .openclaw .openclaw-zhuoyue

# Copy to Mac host (run on Mac)
lume ssh nix -- cat /tmp/openclaw-state.tar.gz > ~/Desktop/openclaw-state.tar.gz

# Copy into OrbStack (run on Mac — OrbStack sees ~/Desktop directly)
orb shell openclaw -- tar xzf /Users/xin.ding/Desktop/openclaw-state.tar.gz -C ~
```

**Option B: Symlink state directory to Mac (if you stored state on Mac)**

If your Lume VM used `~/.openclaw` inside the VM but you want a fresh start, you can reuse the existing config by symlinking:

```bash
# Inside OrbStack — point to Mac state directory
ln -s /Users/xin.ding/.openclaw ~/.openclaw
ln -s /Users/xin.ding/.openclaw-zhuoyue ~/.openclaw-zhuoyue
```

After copying, secure permissions:

```bash
chmod 700 ~/.openclaw
chmod 600 ~/.openclaw/openclaw.json
chmod 700 ~/.openclaw-zhuoyue
chmod 600 ~/.openclaw-zhuoyue/openclaw.json
```

---

## Step 4: Update Config Paths

### Ollama host

The Lume VM reached the host via `192.168.64.1` (Apple NAT). OrbStack uses `host.orbstack.internal`:

```bash
# User: xin
openclaw config set agents.defaults.memorySearch.remote.baseUrl 'http://host.orbstack.internal:11434/v1'

# User: zhuoyue
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue \
  openclaw config set agents.defaults.memorySearch.remote.baseUrl 'http://host.orbstack.internal:11434/v1'
```

### Memory search extra paths

OrbStack sees Mac paths natively, so use the real Mac path instead of the old VirtioFS mount:

```bash
# User: xin
openclaw config set agents.defaults.memorySearch.extraPaths \
  '["/Users/xin.ding/openclaw/xin/transcripts"]'

# User: zhuoyue
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue \
  openclaw config set agents.defaults.memorySearch.extraPaths \
  '["/Users/xin.ding/openclaw/zhuoyue/transcripts"]'
```

### Update symlinks

Replace the old VirtioFS symlinks with Mac-native paths:

```bash
# User: xin
mkdir -p ~/.openclaw/media
ln -sfn /Users/xin.ding/openclaw/xin/media/inbound ~/.openclaw/media/inbound
ln -sfn /Users/xin.ding/openclaw/xin/workspace ~/.openclaw/workspace

# User: zhuoyue
mkdir -p ~/.openclaw-zhuoyue/media
ln -sfn /Users/xin.ding/openclaw/zhuoyue/media/inbound ~/.openclaw-zhuoyue/media/inbound
ln -sfn /Users/xin.ding/openclaw/zhuoyue/workspace ~/.openclaw-zhuoyue/workspace

# Verify
ls -la ~/.openclaw/media/inbound
ls -la ~/.openclaw/workspace
```

---

## Step 5: Update transcript-watcher.sh

The watched directory changes from the VirtioFS mount to the native Mac path. In `scripts/knowledge-base/xin/transcript-watcher.sh` and `scripts/knowledge-base/zhuoyue/transcript-watcher.sh`, update the `TRANSCRIPTS_DIR` variable:

```bash
# Old (Lume VirtioFS)
TRANSCRIPTS_DIR="/Volumes/My Shared Files/xin/transcripts"

# New (OrbStack native path)
TRANSCRIPTS_DIR="/Users/xin.ding/openclaw/xin/transcripts"
```

**inotify on OrbStack:** OrbStack may support `inotifywait` for Mac-backed paths. Test it:

```bash
# Install inotify-tools
sudo apt-get install -y inotify-tools

# Test if inotify works on a Mac-backed path
inotifywait -m /Users/xin.ding/openclaw/xin/transcripts
```

If it produces events when files are added from the Mac, you can replace the polling loop with:

```bash
inotifywait -m -e close_write --format '%f' \
  /Users/xin.ding/openclaw/xin/transcripts
```

If inotify does not work (no events), keep the polling approach unchanged.

---

## Step 6: Install Browser Anti-Detection (Xvfb)

OrbStack Ubuntu supports systemd, so Xvfb can run as a proper service. Apply the settings from [browser-cloudflare-stealth.md](./browser-cloudflare-stealth.md):

```bash
# Already installed in Step 2, but verify:
which Xvfb

# Create the systemd system service for Xvfb
sudo tee /etc/systemd/system/xvfb.service > /dev/null <<'EOF'
[Unit]
Description=Xvfb virtual framebuffer
After=network.target

[Service]
ExecStart=/usr/bin/Xvfb :99 -screen 0 1920x1080x24
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now xvfb

# Verify
systemctl status xvfb
```

Apply browser config for each user:

```bash
# User: xin
openclaw config set browser.headless false
openclaw config set browser.noSandbox true
openclaw config set browser.extraArgs \
  '["--window-size=1920,1080","--user-agent=Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36","--disable-infobars","--disable-extensions","--use-gl=swiftshader","--disable-features=Translate,MediaRouter,AutomationControlled"]'

# User: zhuoyue
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue \
  openclaw config set browser.headless false
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue \
  openclaw config set browser.noSandbox true
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue \
  openclaw config set browser.extraArgs \
  '["--window-size=1920,1080","--user-agent=Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36","--disable-infobars","--disable-extensions","--use-gl=swiftshader","--disable-features=Translate,MediaRouter,AutomationControlled"]'
```

---

## Step 7: Install Gateway as Systemd Service

OrbStack supports user-level systemd, replacing the `nohup ... &` pattern:

```bash
# Allow user services to run without a login session
sudo loginctl enable-linger $USER
```

### User: xin (port 18789)

```bash
openclaw gateway install

systemctl --user enable --now openclaw-gateway

# Verify
systemctl --user status openclaw-gateway
```

The gateway needs `DISPLAY=:99` for the browser to work. Check if `openclaw gateway install` includes it; if not, override the unit:

```bash
systemctl --user edit openclaw-gateway
```

Add:

```ini
[Service]
Environment="DISPLAY=:99"
```

Then reload:

```bash
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway
```

### User: zhuoyue (port 18790)

```bash
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw gateway install

# The service file will be named differently — check what was created
systemctl --user list-units | grep openclaw

# Enable and start it
systemctl --user enable --now openclaw-gateway-zhuoyue

# Add DISPLAY override if needed (same as above)
systemctl --user edit openclaw-gateway-zhuoyue
```

**Port check:** Confirm each gateway is on the expected port:

```bash
ss -ltnp | grep '1878[9-9]\|18790'
```

---

## Step 8: Install Transcript Watcher as Systemd Service

Replace the tmux-based transcript watcher with a systemd user service.

### User: xin

```bash
mkdir -p ~/.config/systemd/user

tee ~/.config/systemd/user/transcript-watcher-xin.service > /dev/null <<'EOF'
[Unit]
Description=OpenClaw transcript watcher (xin)
After=openclaw-gateway.service

[Service]
Environment="OPENCLAW_STATE_DIR=%h/.openclaw"
Environment="TELEGRAM_CHAT_ID=XIN_CHAT_ID"
ExecStart=/Users/xin.ding/openclaw/scripts/knowledge-base/xin/transcript-watcher.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user enable --now transcript-watcher-xin
systemctl --user status transcript-watcher-xin
```

Replace `XIN_CHAT_ID` with xin's Telegram user ID.

### User: zhuoyue

```bash
tee ~/.config/systemd/user/transcript-watcher-zhuoyue.service > /dev/null <<'EOF'
[Unit]
Description=OpenClaw transcript watcher (zhuoyue)
After=openclaw-gateway-zhuoyue.service

[Service]
Environment="OPENCLAW_STATE_DIR=%h/.openclaw-zhuoyue"
Environment="TELEGRAM_CHAT_ID=ZHUOYUE_CHAT_ID"
ExecStart=/Users/xin.ding/openclaw/scripts/knowledge-base/zhuoyue/transcript-watcher.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user enable --now transcript-watcher-zhuoyue
systemctl --user status transcript-watcher-zhuoyue
```

Replace `ZHUOYUE_CHAT_ID` with zhuoyue's Telegram user ID.

---

## Step 9: Shut Down the Lume VM

Once OrbStack is confirmed working (see verification below), stop the Lume VM:

```bash
# On the Mac host
lume stop nix
```

You can delete it later once you're confident nothing was missed:

```bash
lume delete nix
```

---

## Verification

Run through these checks in order:

```bash
# 1. Confirm you can shell in
orb shell openclaw

# 2. Confirm Mac filesystem is visible
ls /Users/xin.ding/openclaw/xin/

# 3. Confirm Ollama is reachable
curl http://host.orbstack.internal:11434/api/tags

# 4. Check state integrity
openclaw doctor

# 5. Confirm systemd gateway running (xin)
systemctl --user status openclaw-gateway

# 6. Confirm channels connected
openclaw channels status --probe

# 7. Confirm browser works without Cloudflare block
openclaw browser navigate "https://nowsecure.nl"

# 8. Confirm transcript watcher running
systemctl --user status transcript-watcher-xin

# 9. Trigger end-to-end test
#    Send a voice message via Telegram → verify transcript-watcher picks it up
#    Check: systemctl --user status transcript-watcher-xin
#           journalctl --user -u transcript-watcher-xin -f
```

---

## Post-Migration Notes

### Logs

```bash
# Gateway logs (replaces /tmp/openclaw-gateway.log)
journalctl --user -u openclaw-gateway -f

# Transcript watcher logs
journalctl --user -u transcript-watcher-xin -f
journalctl --user -u transcript-watcher-zhuoyue -f

# Xvfb
journalctl -u xvfb -f
```

### After OrbStack machine restart

Systemd user services restart automatically — no manual commands needed. Verify after a restart with:

```bash
systemctl --user list-units --state=active | grep openclaw
```

### Ollama accessibility

OrbStack routes `host.orbstack.internal` to the Mac. Ollama must still listen on all interfaces:

```bash
# On Mac host — verify or restart with:
OLLAMA_HOST=0.0.0.0 ollama serve
```

To make this permanent, add `export OLLAMA_HOST=0.0.0.0` to `~/.zshrc` (or a launchd plist).

### hotwords path update

If the transcript-watcher or agent writes hotwords, update any references from:

```
/Volumes/My Shared Files/xin/config/hotwords.txt
```

to:

```
/Users/xin.ding/openclaw/xin/config/hotwords.txt
```

---

## Troubleshooting

### Gateway fails to start with "DISPLAY not set"

The gateway needs `DISPLAY=:99` when `browser.headless` is `false`. Add the environment override:

```bash
systemctl --user edit openclaw-gateway
# Add under [Service]:
# Environment="DISPLAY=:99"
systemctl --user daemon-reload && systemctl --user restart openclaw-gateway
```

### `host.orbstack.internal` not resolving inside VM

Verify the name resolves:

```bash
getent hosts host.orbstack.internal
```

If it fails, check OrbStack docs for your version. As a fallback, `host.internal` is an alias that OrbStack also provides.

### inotify not firing on Mac-backed paths

If `inotifywait` produces no events for files written from the Mac, OrbStack's filesystem bridge does not propagate inotify for that path. Keep the polling loop in `transcript-watcher.sh` unchanged.

### Memory index after migration

After updating paths, reindex to pick up the new locations:

```bash
openclaw memory index --force

# zhuoyue
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw memory index --force
```

### Permissions on Mac paths

OrbStack mounts Mac home under `/Users/xin.ding/` with the same UID/GID as your Mac user. File creation from inside OrbStack will appear as your Mac user — no permission issues expected. If you see `Permission denied`, verify OrbStack machine settings.
