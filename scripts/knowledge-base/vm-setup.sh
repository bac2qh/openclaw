#!/bin/bash
# OpenClaw VM Setup Script
#
# Run this inside the Lume VM to install OpenClaw and configure it
# for the personal knowledge base system.
#
# Usage: curl -fsSL <url>/vm-setup.sh | bash
#        or: ./vm-setup.sh

set -euo pipefail

echo "=== OpenClaw VM Setup ==="
echo ""

# Detect OS
if [ -f /etc/debian_version ]; then
    OS="debian"
elif [ -f /etc/redhat-release ]; then
    OS="redhat"
elif [[ "$(uname)" == "Darwin" ]]; then
    OS="macos"
else
    echo "Warning: Unknown OS, assuming Debian-based"
    OS="debian"
fi

# Install Node.js
echo "Installing Node.js 22..."
if [ "$OS" = "debian" ]; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
elif [ "$OS" = "redhat" ]; then
    curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
    sudo yum install -y nodejs
elif [ "$OS" = "macos" ]; then
    if command -v brew &> /dev/null; then
        brew install node@22
    else
        echo "Please install Homebrew first: https://brew.sh"
        exit 1
    fi
fi

echo "Node.js version: $(node --version)"

# Install pnpm
echo "Installing pnpm..."
npm install -g pnpm

# Install OpenClaw
echo "Installing OpenClaw..."
npm install -g openclaw@latest

# Verify installation
echo ""
echo "=== Verifying Installation ==="
openclaw --version

# Create directories
echo ""
echo "=== Creating Directories ==="
mkdir -p ~/.openclaw/workspace/memory
mkdir -p ~/.openclaw/workspace/transcripts

# Check for shared folder
if [ -d /mnt/transcripts ]; then
    echo "Found shared transcripts folder at /mnt/transcripts"
    ln -sf /mnt/transcripts ~/.openclaw/workspace/transcripts
    echo "Symlinked to ~/.openclaw/workspace/transcripts"
else
    echo "Note: /mnt/transcripts not found."
    echo "If using Lume, ensure shared_directories is configured."
fi

# Create initial memory file
if [ ! -f ~/.openclaw/workspace/MEMORY.md ]; then
    cat > ~/.openclaw/workspace/MEMORY.md << 'EOF'
# Long-Term Memory

## About Me
- Name: [Your name]
- Role: [Your role]

## Preferences
- [Add your preferences]

## Important Context
- [Key information]

## Active Projects
- [Project list]

## Decisions Log
<!-- Agent will append decisions here -->
EOF
    echo "Created initial MEMORY.md"
fi

# Install transcript-watcher LaunchAgent (macOS only)
if [ "$OS" = "macos" ]; then
    echo ""
    echo "=== Installing Transcript Watcher LaunchAgent ==="

    PLIST_SOURCE="$HOME/openclaw/scripts/knowledge-base/com.user.transcript-watcher.plist"
    PLIST_DEST="$HOME/Library/LaunchAgents/com.user.transcript-watcher.plist"

    if [ -f "$PLIST_SOURCE" ]; then
        mkdir -p "$HOME/Library/LaunchAgents"
        cp "$PLIST_SOURCE" "$PLIST_DEST"
        echo "Copied plist to $PLIST_DEST"
        echo ""
        echo "IMPORTANT: Edit the plist to set your credentials:"
        echo "  1. Replace YOUR_USERNAME with your actual username"
        echo "  2. Replace YOUR_CHAT_ID_HERE with your Telegram chat ID"
        echo "     (Get it from @userinfobot on Telegram)"
        echo ""
        read -p "Press Enter after editing the plist, or Ctrl+C to skip..."

        # Offer to load the agent
        read -p "Load the transcript watcher now? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            launchctl load "$PLIST_DEST"
            echo "LaunchAgent loaded. Check status with:"
            echo "  launchctl list | grep transcript-watcher"
            echo "  tail -f /tmp/transcript-watcher.log"
        else
            echo "To load later, run:"
            echo "  launchctl load $PLIST_DEST"
        fi
    else
        echo "Warning: Could not find plist at $PLIST_SOURCE"
        echo "You can manually install it later from the openclaw repo."
    fi
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "1. Configure API keys:"
echo "   openclaw config set providers.anthropic.apiKey 'sk-ant-...'"
echo "   openclaw config set providers.openai.apiKey 'sk-...'"
echo ""
echo "2. Configure Telegram:"
echo "   openclaw config set channels.telegram.token 'YOUR_BOT_TOKEN'"
echo "   openclaw config set channels.telegram.allowlist '[\"YOUR_USER_ID\"]'"
echo ""
echo "3. Enable memory search:"
echo "   openclaw config set agents.defaults.memorySearch.enabled true"
echo ""
echo "4. Enable session memory for transcript processing:"
echo "   openclaw config set agents.defaults.memorySearch.experimental.sessionMemory true"
echo ""
echo "5. Start the gateway:"
echo "   openclaw gateway run"
echo ""
