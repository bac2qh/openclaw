# Reduce Cloudflare Blocks in Headless Lume VM Browser

OpenClaw runs in a headless Lume VM (Ubuntu). The browser tool launches Chrome with `--headless=new`, which Cloudflare detects via TLS fingerprint (JA3/JA4) and JS environment probes. Running headful Chrome on a virtual framebuffer (Xvfb) produces an identical TLS signature to a real browser.

## 1. Install Xvfb on the VM

```bash
ssh exe.dev
ssh vm-name
sudo apt-get install -y xvfb
```

## 2. Start Xvfb virtual display

```bash
Xvfb :99 -screen 0 1920x1080x24 &
export DISPLAY=:99
```

To persist across reboots, create a systemd service:

```ini
# /etc/systemd/system/xvfb.service
[Unit]
Description=Xvfb virtual framebuffer
After=network.target

[Service]
ExecStart=/usr/bin/Xvfb :99 -screen 0 1920x1080x24
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now xvfb
```

## 3. Apply openclaw browser config

```bash
openclaw config set browser.headless false
openclaw config set browser.noSandbox true
openclaw config set browser.extraArgs '["--window-size=1920,1080","--user-agent=Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36","--disable-infobars","--disable-extensions","--use-gl=swiftshader","--disable-features=Translate,MediaRouter,AutomationControlled"]'
```

### What each setting does

| Setting | Purpose |
|---------|---------|
| `headless: false` | Run headful Chrome against Xvfb; eliminates the distinct headless TLS fingerprint (JA3/JA4) that Cloudflare flags |
| `noSandbox: true` | Required in VM/container environments |
| `--window-size=1920,1080` | Realistic viewport |
| `--user-agent=...` | Matches real Chrome on Linux |
| `--disable-infobars` | Hides automation infobar |
| `--disable-extensions` | Disables automation extension |
| `--use-gl=swiftshader` | Simulates GPU to reduce fingerprint anomalies |
| `--disable-features=Translate,MediaRouter,AutomationControlled` | Removes automation signals from JS environment |

## 4. Restart the gateway with DISPLAY set

```bash
pkill -9 -f openclaw-gateway || true
DISPLAY=:99 nohup openclaw gateway run --bind loopback --port 18789 --force > /tmp/openclaw-gateway.log 2>&1 &
```

## 5. Verify

```bash
# Xvfb running
ps aux | grep Xvfb

# DISPLAY is set for the process
cat /proc/$(pgrep -f openclaw-gateway)/environ | tr '\0' '\n' | grep DISPLAY

# Test against a Cloudflare-protected site
openclaw browser navigate "https://nowsecure.nl"
```

Confirm the snapshot shows the actual page content, not a Cloudflare challenge/captcha.
