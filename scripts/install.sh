#!/usr/bin/env bash
# Install ctm on Raspberry Pi (or any Linux system).
# Run as: bash scripts/install.sh
set -euo pipefail

INSTALL_DIR="/usr/local/bin"
SERVICE_NAME="claude-token-monitor"
ZIG_VERSION="0.13.0"
ARCH=$(uname -m)

# Map arch to Zig's naming
case "$ARCH" in
  aarch64|arm64) ZIG_ARCH="aarch64-linux" ;;
  armv7l|armhf)  ZIG_ARCH="armv7a-linux-gnueabihf" ;;
  x86_64)        ZIG_ARCH="x86_64-linux" ;;
  *)
    echo "Unsupported arch: $ARCH"
    exit 1
    ;;
esac

# Check for Zig
if ! command -v zig &>/dev/null; then
  echo "Zig not found. Installing Zig $ZIG_VERSION for $ZIG_ARCH..."
  ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz"
  curl -fL "$ZIG_URL" | tar -xJ -C /tmp
  sudo mv "/tmp/zig-${ZIG_ARCH}-${ZIG_VERSION}" /opt/zig
  sudo ln -sf /opt/zig/zig /usr/local/bin/zig
  echo "Zig installed."
fi

echo "Building ctm..."
zig build -Doptimize=ReleaseSafe

echo "Installing ctm to $INSTALL_DIR..."
sudo cp zig-out/bin/ctm "$INSTALL_DIR/ctm"
sudo chmod +x "$INSTALL_DIR/ctm"

# Set up config directory
CONFIG_DIR="$HOME/.config/ctm"
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.json" ]; then
  cp config.example.json "$CONFIG_DIR/config.json"
  echo "Config created at $CONFIG_DIR/config.json — edit it before starting the daemon."
fi

# Install systemd service (optional, requires systemd)
if command -v systemctl &>/dev/null; then
  echo "Installing systemd service..."
  USER_NAME=$(whoami)
  sudo cp systemd/claude-token-monitor.service \
    "/etc/systemd/system/claude-token-monitor@${USER_NAME}.service"
  sudo systemctl daemon-reload
  echo ""
  echo "To enable and start the daemon:"
  echo "  sudo systemctl enable --now claude-token-monitor@${USER_NAME}"
  echo ""
  echo "To view logs:"
  echo "  journalctl -u claude-token-monitor@${USER_NAME} -f"
fi

echo "Done. Run 'ctm --help' for usage."
