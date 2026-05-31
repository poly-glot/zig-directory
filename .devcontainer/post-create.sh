#!/usr/bin/env bash
set -euo pipefail

echo "=== Dmoz Zig Development Container Setup ==="

# Install system packages
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends \
  curl wget jq htop xz-utils unzip wrk

# Install Zig 0.15.2
ZIG_VERSION="0.15.2"
ZIG_ARCH="$(uname -m)"
if [ "$ZIG_ARCH" = "x86_64" ]; then
  ZIG_TARGET="x86_64-linux"
elif [ "$ZIG_ARCH" = "aarch64" ]; then
  ZIG_TARGET="aarch64-linux"
else
  echo "Unsupported architecture: $ZIG_ARCH"
  exit 1
fi

echo "Installing Zig ${ZIG_VERSION} for ${ZIG_TARGET}..."
curl -sL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_TARGET}-${ZIG_VERSION}.tar.xz" | sudo tar -xJ -C /usr/local
sudo ln -sf "/usr/local/zig-${ZIG_TARGET}-${ZIG_VERSION}/zig" /usr/local/bin/zig

# Install ZLS (Zig Language Server)
echo "Installing ZLS..."
ZLS_URL="https://github.com/zigtools/zls/releases/latest/download/zls-${ZIG_TARGET}.tar.xz"
curl -sL "$ZLS_URL" | sudo tar -xJ -C /usr/local/bin

# Upgrade Claude Code to the latest release (the devcontainer feature may pin an
# older one). The node feature's global npm prefix (/usr/local) is root-owned, so
# `npm install -g` as the vscode user fails with EACCES. The proper fix is NOT to
# sudo-install (that leaves root-owned files in ~/.npm cache and breaks later
# user-level npm); instead point npm's global prefix at a user-owned directory and
# put its bin first on PATH so the upgraded claude wins over the feature's copy.
echo "Upgrading Claude Code to latest..."
NPM_GLOBAL="$HOME/.npm-global"
mkdir -p "$NPM_GLOBAL"
npm config set prefix "$NPM_GLOBAL"   # persists to ~/.npmrc for future npm -g installs
export PATH="$NPM_GLOBAL/bin:$PATH"
npm install -g @anthropic-ai/claude-code@latest

# Install Deno
echo "Installing Deno..."
curl -fsSL https://deno.land/install.sh | sh
export DENO_INSTALL="/home/vscode/.deno"
export PATH="$DENO_INSTALL/bin:$PATH"

# Verify installations
echo ""
echo "=== Installed versions ==="
zig version
zls --version 2>/dev/null || echo "ZLS: installed (version check may not be supported)"
deno --version
docker --version
wrk --version 2>/dev/null || echo "wrk: installed"
git --version
echo -n "claude " && claude --version 2>/dev/null || echo "claude: installed"

# Configure git
git config --global core.autocrlf input
git config --global init.defaultBranch main
git config --global --add safe.directory /workspaces/zig-directory

# Add aliases to .zshrc
cat >> /home/vscode/.zshrc << 'ALIASES'

# User-owned npm global prefix (so `npm install -g` and the upgraded claude work without sudo)
export PATH="$HOME/.npm-global/bin:$PATH"

# Deno path
export DENO_INSTALL="/home/vscode/.deno"
export PATH="$DENO_INSTALL/bin:$PATH"

# Zig shortcuts
alias zb="zig build"
alias zt="zig build test"
alias zr="zig build run"
alias zfmt="zig fmt src/"
alias ztest="zig test"

# Claude shortcut
alias c="claude"

# Deno/Fresh shortcuts
alias di="deno install"
alias dt="deno task"
alias fresh="deno run -A -r jsr:@fresh/init"

# Bring up the full stack (dmozdb + Fresh web).
#   dev  - hot-reloading web server (vite)
#   prod - built bundle served live, no auto-refresh
alias dev="bash /workspaces/zig-directory/.devcontainer/run.sh dev"
alias prod="bash /workspaces/zig-directory/.devcontainer/run.sh prod"

# Docker shortcuts
alias db="docker build -t dmozdb ."
alias dr="docker run --rm -p 8080:8080 dmozdb"

# Load testing
alias loadtest="wrk -t4 -c100 -d30s http://localhost:8080/"

# Git shortcuts
alias gs="git status"
alias gd="git diff"
alias gl="git log --oneline -20"
alias gp="git push"
ALIASES

echo ""
echo "=== Setup complete ==="
echo "Run 'zig build' to compile, 'zig build test' to test, 'zig build run' to run."
echo "Run 'db' to docker build, 'dr' to docker run, 'loadtest' for wrk load test."
