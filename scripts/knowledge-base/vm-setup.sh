#!/bin/bash
# OpenClaw VM Setup Script
#
# Run this inside the Lume VM to install OpenClaw and configure it
# for the personal knowledge base system.
#
# Usage: curl -fsSL <url>/vm-setup.sh | bash
#        or: ./vm-setup.sh
#        or: OPENCLAW_STATE_DIR=~/.openclaw-wife ./vm-setup.sh  # For second user
#
# Environment variables:
#   OPENCLAW_STATE_DIR - OpenClaw state directory (default: ~/.openclaw)

set -euo pipefail

OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"

echo "=== OpenClaw VM Setup ==="
echo "State directory: $OPENCLAW_STATE_DIR"
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
mkdir -p "${OPENCLAW_STATE_DIR}/workspace/memory"
mkdir -p "${OPENCLAW_STATE_DIR}/media"

# Check for shared folder (user-specific paths expected)
# Note: For multi-user setup, symlink to /Volumes/My Shared Files/{USER_PROFILE}/...
echo "Note: After setup, create symlinks to shared folders:"
echo "  ln -s '/Volumes/My Shared Files/{USER_PROFILE}/media/inbound' ${OPENCLAW_STATE_DIR}/media/inbound"
echo "  ln -s '/Volumes/My Shared Files/{USER_PROFILE}/workspace' ${OPENCLAW_STATE_DIR}/workspace"

# Create initial memory file
if [ ! -f "${OPENCLAW_STATE_DIR}/workspace/MEMORY.md" ]; then
    cat > "${OPENCLAW_STATE_DIR}/workspace/MEMORY.md" << 'EOF'
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

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "1. Set OPENCLAW_STATE_DIR (if using non-default location):"
echo "   export OPENCLAW_STATE_DIR=${OPENCLAW_STATE_DIR}"
echo ""
echo "2. Configure API keys:"
echo "   openclaw config set providers.anthropic.apiKey 'sk-ant-...'"
echo "   openclaw config set providers.openai.apiKey 'sk-...'"
echo ""
echo "3. Configure Telegram:"
echo "   openclaw config set channels.telegram.token 'YOUR_BOT_TOKEN'"
echo "   openclaw config set channels.telegram.allowlist '[\"YOUR_USER_ID\"]'"
echo ""
echo "4. Enable memory search:"
echo "   openclaw config set agents.defaults.memorySearch.enabled true"
echo ""
echo "5. Enable session memory for transcript processing:"
echo "   openclaw config set agents.defaults.memorySearch.experimental.sessionMemory true"
echo ""
echo "6. Set gateway port (if running multiple instances):"
echo "   openclaw config set gateway.port 18789  # Default for first user"
echo "   openclaw config set gateway.port 18790  # For second user"
echo ""
echo "7. Start the gateway:"
echo "   openclaw gateway run"
echo ""
