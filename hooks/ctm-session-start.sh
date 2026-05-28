#!/usr/bin/env bash
# Claude Code hook — fires when a new coding session starts.
#
# Installation (Claude Code CLI):
#   Add this script to your Claude Code hooks configuration.
#   See: https://docs.anthropic.com/en/docs/claude-code/hooks
#
# What it does:
#   Pings the ctm daemon on your Pi to confirm the LAN link is up before
#   you start a long coding session. A failed ping prints a warning but
#   never blocks Claude Code from starting.

PI_HOST="${CTM_PI_HOST:-raspberrypi.local}"
PI_PORT="${CTM_PI_PORT:-7373}"
CTM_AGENT="${CTM_AGENT_BIN:-ctm-agent}"

# Prefer ctm-agent --ping if it's installed; fall back to raw curl.
if command -v "$CTM_AGENT" >/dev/null 2>&1; then
    if "$CTM_AGENT" --ping 2>/dev/null; then
        exit 0
    fi
else
    if curl --silent --max-time 3 "http://${PI_HOST}:${PI_PORT}/health" >/dev/null 2>&1; then
        exit 0
    fi
fi

echo "[ctm] WARNING: Pi not reachable at ${PI_HOST}:${PI_PORT}" >&2
echo "[ctm] Token usage will be spooled locally and shipped when the Pi comes back." >&2
echo "[ctm] To silence this warning: ensure ctm --daemon is running on the Pi." >&2
exit 0   # never block the session
