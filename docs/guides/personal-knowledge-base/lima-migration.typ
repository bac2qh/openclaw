#set document(title: "Migrate from Lume/OrbStack VM to Lima Ubuntu")
#set page(paper: "a4", margin: (x: 2.5cm, y: 2.5cm))
#set text(size: 10.5pt)
#set par(leading: 0.65em)

#show raw.where(block: true): block.with(
  fill: luma(240),
  inset: (x: 9pt, y: 7pt),
  radius: 3pt,
  width: 100%,
)

= Migrate from Lume/OrbStack VM to Lima Ubuntu

Migrate your OpenClaw gateway from a Lume VM or OrbStack machine to a Lima VM. Lima provides full mount isolation — only `~/openclaw/` is visible inside the VM, compared to OrbStack which exposes your entire home directory.

== Why Lima (Not OrbStack)

OrbStack mounts `~/` read-write into every VM and *this cannot be disabled*. That means the VM can see `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/Documents`, and all other sensitive directories.

Lima solves this with configurable mounts. The `mounts:` list replaces all defaults — an empty list means no Mac paths are visible at all. This guide mounts only `~/openclaw/` writable.

== What Changes

#table(
  columns: (1.1fr, 1.4fr, 1.5fr),
  stroke: 0.5pt,
  fill: (_, row) => if row == 0 { luma(220) } else { none },
  inset: 6pt,
  [*Component*], [*Lume (old)*], [*Lima (new)*],
  [VM create], [`lume create --os ubuntu`], [`limactl create lima-openclaw.yaml`],
  [VM shell], [`lume ssh nix`], [`limactl shell openclaw`],
  [VM start/stop], [`lume start/stop nix`], [`limactl start/stop openclaw`],
  [Shared files mount], [`/Volumes/My Shared Files/`], [`/Users/xin.ding/openclaw` (explicit only)],
  [Host IP from VM], [`192.168.64.1`], [`host.lima.internal`],
  [State dirs], [inside VM or symlinked], [inside VM disk only (no symlink option)],
  [Gateway management], [`nohup openclaw gateway run &`], [`openclaw gateway install` (systemd)],
  [Transcript watcher], [tmux session], [systemd user service],
)

== What Stays the Same

- Host-side processes: mlx-audio (launchd), Ollama, rsync/sync, NAS archival
- Directory structure on Mac: `~/openclaw/xin/` and `~/openclaw/zhuoyue/`
- OpenClaw config keys and values (providers, channels, agents, browser settings)
- Port convention: xin → 18789, zhuoyue → 18790
- All scripts under `~/openclaw/scripts/` (path is identical inside VM)

== Step 0: lima.yaml Configuration

Save this file as `~/lima-openclaw.yaml` on your Mac:

```yaml
vmType: vz
rosetta:
  enabled: true
  binfmt: true
cpus: 4
memory: 8GiB
disk: 50GiB
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
    arch: "aarch64"
mounts:
  - location: "~/openclaw"
    writable: true
    mountPoint: "/Users/xin.ding/openclaw"
portForwards:
  - guestPort: 18789
    hostIP: "127.0.0.1"
  - guestPort: 18790
    hostIP: "127.0.0.1"
provision:
  - mode: system
    script: |
      #!/bin/bash
      set -eux
      if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
        apt-get install -y nodejs xvfb inotify-tools
      fi
  - mode: user
    script: |
      #!/bin/bash
      set -eux
      npm install -g openclaw@latest || true
```

*Isolation design:*

- `mounts:` overrides Lima's defaults entirely — the VM cannot see `~/.ssh`, `~/.aws`, `~/Documents`, or any other Mac directory.
- `mountPoint: "/Users/xin.ding/openclaw"` matches the host path exactly, so all existing scripts work unchanged inside the VM.
- State dirs (`~/.openclaw`, `~/.openclaw-zhuoyue`) live on the VM disk only.
- `portForwards` binds gateway ports to loopback on the Mac host.
- Provision scripts run once at VM creation to install Node.js, Xvfb, inotify-tools, and OpenClaw.

== Step 1: Install Lima and Create VM

```bash
# Install Lima via Homebrew
brew install lima

# Verify
limactl --version
```

Create the VM from the config file:

```bash
# Create VM named "openclaw" from the yaml
limactl create --name openclaw ~/lima-openclaw.yaml

# Start the VM (provision scripts run here — takes 2-5 minutes)
limactl start openclaw
```

Shell into the VM:

```bash
limactl shell openclaw
```

Verify the mount is in place and the VM cannot see your full home directory:

```bash
# Confirm only ~/openclaw is visible
ls /Users/xin.ding/openclaw/xin/

# Confirm sensitive dirs are NOT accessible
ls /Users/xin.ding/.ssh 2>&1   # Should say "No such file or directory"
ls /Users/xin.ding/Documents 2>&1  # Should say "No such file or directory"
```

== Step 2: Install OpenClaw

The provision script runs `npm install -g openclaw@latest` automatically. Verify it succeeded:

```bash
# Inside Lima
openclaw --version
```

If the provision step failed or you need to update:

```bash
npm install -g openclaw@latest
openclaw --version
```

== Step 3: Transfer State from Old VM

State directories (`~/.openclaw`, `~/.openclaw-zhuoyue`) live *inside the VM disk* — copy them from the old VM via the shared mount.

*From a Lume VM:*

```bash
# On Lume VM — create archive
tar czf /tmp/openclaw-state.tar.gz -C ~ .openclaw .openclaw-zhuoyue

# Copy to Mac host (run on Mac)
lume ssh nix -- cat /tmp/openclaw-state.tar.gz > ~/Desktop/openclaw-state.tar.gz

# Copy the archive into the Lima shared mount (run on Mac)
cp ~/Desktop/openclaw-state.tar.gz ~/openclaw/openclaw-state.tar.gz

# Inside Lima — extract from the shared mount into home dir
tar xzf /Users/xin.ding/openclaw/openclaw-state.tar.gz -C ~

# Clean up
rm /Users/xin.ding/openclaw/openclaw-state.tar.gz
```

*From an OrbStack machine:*

```bash
# Inside OrbStack — create archive on shared Mac path
tar czf /Users/xin.ding/openclaw/openclaw-state.tar.gz -C ~ .openclaw .openclaw-zhuoyue

# Inside Lima — extract
tar xzf /Users/xin.ding/openclaw/openclaw-state.tar.gz -C ~

# Clean up
rm /Users/xin.ding/openclaw/openclaw-state.tar.gz
```

After extracting, secure permissions:

```bash
chmod 700 ~/.openclaw
chmod 600 ~/.openclaw/openclaw.json
chmod 700 ~/.openclaw-zhuoyue
chmod 600 ~/.openclaw-zhuoyue/openclaw.json
```

== Step 4: Update Config Paths

=== Ollama host

Lima uses `host.lima.internal`:

```bash
# User: xin
openclaw config set agents.defaults.memorySearch.remote.baseUrl \
  'http://host.lima.internal:11434/v1'

# User: zhuoyue
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue \
  openclaw config set agents.defaults.memorySearch.remote.baseUrl \
  'http://host.lima.internal:11434/v1'
```

=== Memory search extra paths

```bash
# User: xin
openclaw config set agents.defaults.memorySearch.extraPaths \
  '["/Users/xin.ding/openclaw/xin/transcripts"]'

# User: zhuoyue
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue \
  openclaw config set agents.defaults.memorySearch.extraPaths \
  '["/Users/xin.ding/openclaw/zhuoyue/transcripts"]'
```

=== Update symlinks

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

== Step 5: Update transcript-watcher.sh

If coming from a Lume VM (VirtioFS mount), update the `TRANSCRIPTS_DIR` variable:

```bash
# Old (Lume VirtioFS)
TRANSCRIPTS_DIR="/Volumes/My Shared Files/xin/transcripts"

# New (Lima mount path — same as Mac path)
TRANSCRIPTS_DIR="/Users/xin.ding/openclaw/xin/transcripts"
```

*inotify on Lima:* Lima's VirtioFS supports `inotifywait` for mounted paths. Test it:

```bash
inotifywait -m /Users/xin.ding/openclaw/xin/transcripts
```

If events fire when files are created on the Mac, replace the polling loop with:

```bash
inotifywait -m -e close_write --format '%f' \
  /Users/xin.ding/openclaw/xin/transcripts
```

If no events appear, keep the polling loop unchanged.

== Step 6: Xvfb Systemd Service and Browser Config

Apply the settings from #link("./browser-cloudflare-stealth.md")[browser-cloudflare-stealth.md]:

```bash
# Verify Xvfb was installed by provision script
which Xvfb

# Create system service for Xvfb
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

== Step 7: Install Gateway as Systemd Service

```bash
# Allow user services to run without a login session
sudo loginctl enable-linger $USER
```

=== User: xin (port 18789)

```bash
openclaw gateway install
systemctl --user enable --now openclaw-gateway
systemctl --user status openclaw-gateway
```

If the gateway needs `DISPLAY=:99` (browser.headless = false):

```bash
systemctl --user edit openclaw-gateway
# Add under [Service]:
# Environment="DISPLAY=:99"
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway
```

=== User: zhuoyue (port 18790)

```bash
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw gateway install
systemctl --user list-units | grep openclaw
systemctl --user enable --now openclaw-gateway-zhuoyue
systemctl --user edit openclaw-gateway-zhuoyue   # Add DISPLAY if needed
```

*Port check:*

```bash
ss -ltnp | grep '1878[9-9]\|18790'
```

== Step 8: Install Transcript Watcher as Systemd Service

=== User: xin

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

=== User: zhuoyue

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

== Step 9: Shut Down the Old VM

*If migrating from Lume:*

```bash
lume stop nix
lume delete nix   # Only once you're confident nothing was missed
```

*If migrating from OrbStack:*

```bash
orb stop openclaw
orb delete openclaw   # Only once you're confident nothing was missed
```

== Verification

Run through these checks in order:

```bash
# 1. Confirm you can shell in
limactl shell openclaw

# 2. Confirm only ~/openclaw is visible (isolation check)
ls /Users/xin.ding/openclaw/xin/
ls /Users/xin.ding/.ssh 2>&1   # Must fail

# 3. Confirm Ollama is reachable
curl http://host.lima.internal:11434/api/tags

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
#    journalctl --user -u transcript-watcher-xin -f
```

== Post-Migration Notes

=== Logs

```bash
# Gateway logs
journalctl --user -u openclaw-gateway -f

# Transcript watcher logs
journalctl --user -u transcript-watcher-xin -f
journalctl --user -u transcript-watcher-zhuoyue -f

# Xvfb
journalctl -u xvfb -f
```

=== VM lifecycle

```bash
limactl start openclaw
limactl stop openclaw
limactl shell openclaw
limactl list
```

Systemd user services restart automatically when the VM starts.

=== Ollama accessibility

Lima routes `host.lima.internal` to the Mac. Ollama must listen on all interfaces:

```bash
# On Mac host
OLLAMA_HOST=0.0.0.0 ollama serve
```

To make permanent, add `export OLLAMA_HOST=0.0.0.0` to `~/.zshrc` (or a launchd plist).

=== VM storage location

Lima VM disks are stored at `~/.lima/openclaw/`. Back up state before experimenting:

```bash
# Inside Lima — back up state to shared mount
tar czf /Users/xin.ding/openclaw/openclaw-state-backup.tar.gz \
  -C ~ .openclaw .openclaw-zhuoyue
```

== Troubleshooting

=== `host.lima.internal` not resolving inside VM

```bash
getent hosts host.lima.internal
```

Requires Lima 0.14+. As a fallback, use the default gateway IP:

```bash
ip route show default | awk '{print $3}'
```

=== Mount not appearing at expected path

```bash
mount | grep openclaw
cat ~/.lima/openclaw/lima.yaml
```

If still missing: `limactl stop openclaw && limactl start openclaw`

=== inotify not firing on mounted paths

```bash
inotifywait -m /Users/xin.ding/openclaw/xin/transcripts &
touch /Users/xin.ding/openclaw/xin/transcripts/test.txt  # on Mac
```

If no events appear, fall back to the polling loop in `transcript-watcher.sh`.

=== Gateway fails to start with "DISPLAY not set"

```bash
systemctl --user edit openclaw-gateway
# Add under [Service]:
# Environment="DISPLAY=:99"
systemctl --user daemon-reload && systemctl --user restart openclaw-gateway
```

=== vmType: vz requires macOS 13+

```bash
sw_vers -productVersion   # Must be 13.0 or higher
uname -m                  # Must be arm64
```

If on macOS 12 or earlier, change `vmType: vz` to `vmType: qemu` in `lima-openclaw.yaml`, remove the `rosetta:` block, and use an `amd64` cloud image.

=== Memory index after migration

```bash
openclaw memory index --force

# zhuoyue
OPENCLAW_STATE_DIR=~/.openclaw-zhuoyue openclaw memory index --force
```
