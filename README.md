# Claude Token Monitor (ctm)

[![CI](https://github.com/GageLawton/Claude-Token-Monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/GageLawton/Claude-Token-Monitor/actions/workflows/ci.yml)

A lightweight, native **Zig** monitor for Claude Code token usage. Designed to
run quietly in the background on a Raspberry Pi (or any Linux box) and email
you the moment your 5-hour token window resets.

Inspired by
[Maciek-roboblog/Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor),
re-implemented in Zig with email alerts, daemon mode, and remote Pi deployment added.

> **Key difference from similar tools:** `ctm` is designed for a two-machine setup.
> Your dev machine runs `ctm-agent`, which ships token data to a Raspberry Pi running
> `ctm --daemon`. The Pi sends email alerts without needing Claude Code installed on it.

---

## Why this exists

The Claude Pro / Max plans use a rolling **5-hour token window**. Knowing when
that window resets (and getting a notification when it does) means you don't
have to keep refreshing the terminal to see if you're back online.

`ctm` runs as a tiny native daemon, reads the JSONL session files Claude Code
already writes to `~/.claude/projects/`, and sends an email the moment your
quota frees up.

---

## Architecture

```
[ Dev Machine (Mac/Linux) ]              [ Raspberry Pi Zero ]
  Claude Code                              ctm --daemon
  ~/.claude/projects/*.jsonl               (ingest_server.enabled = true)
  ctm-agent  ──── HTTP POST ──────────►   :7373/ingest
  (polls for new lines every 500ms)        │
                                           ├─ email on reset
                                           └─ email on threshold
```

`ctm-agent` uses **inotify** on Linux (stat-poll fallback on macOS) to detect
new JSONL lines and ships only the new bytes — nothing is ever re-read.
The Pi holds entries in memory and prunes anything older than 6 hours,
keeping RSS well under 8 MB.

---

## Features

- **Live terminal dashboard** — usage bar, burn rate, reset countdown, cost
- **Daemon mode** — runs in the background, no terminal required
- **Email notifications** — alerts on reset, threshold, and quota events
- **No login required** — piggybacks on Claude Code's existing session files
- **Multi-plan support** — Pro, Max 5x, Max 20x
- **Raspberry Pi friendly** — single static binary, systemd unit included
- **Fully tested** — unit tests across every module, `kcov` coverage support

---

## Install

### Quick start (Raspberry Pi or Linux)

```bash
git clone https://github.com/GageLawton/Claude-Token-Monitor
cd Claude-Token-Monitor
bash scripts/install.sh
```

The install script will:

1. Download Zig 0.13 if you don't have it
2. Build the `ctm` binary
3. Copy it to `/usr/local/bin/ctm`
4. Drop a starter config in `~/.config/ctm/config.json`
5. Install a systemd service template

### Manual build

```bash
zig build -Doptimize=ReleaseSafe
sudo cp zig-out/bin/ctm /usr/local/bin/
```

### Cross-compile for a Pi from another machine

```bash
# Pi 4 / 5 (64-bit OS)
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe

# Pi 2 / 3 (32-bit ARMv7 OS)
zig build -Dtarget=arm-linux-musleabihf -Doptimize=ReleaseSafe

# Pi Zero / Zero W (ARMv6 — no official Zig binary, must cross-compile)
zig build -Dtarget=arm-linux-musleabihf -Dcpu=arm1176jzf_s -Doptimize=ReleaseSafe
```

The resulting binary in `zig-out/bin/ctm` is fully static — copy it to the Pi with `scp`.

---

## Usage

```text
ctm              # live dashboard (Ctrl+C to exit)
ctm --status     # one-shot status print
ctm --daemon     # detach into background
ctm --help       # show all options
```

### Dashboard

```
╔══════════════════════════════════════════════════╗
║        CLAUDE TOKEN MONITOR  (ctm)               ║
╠══════════════════════════════════════════════════╣
║  Plan:      Pro                                  ║
║  Window:    5h rolling  (resets in 2h 17m)       ║
╠══════════════════════════════════════════════════╣
║  Usage:    [████████████░░░░░░░░░░░] 52.3%        ║
║                46,024 / 88,000 tokens             ║
║           Remaining: 41,976 tokens                ║
╠══════════════════════════════════════════════════╣
║  Cost:    $0.7340 (this window)                  ║
║  Burn:    ~12,400 tokens/hour                    ║
╚══════════════════════════════════════════════════╝
```

---

## Configuration

`ctm` looks for config in this order:

1. Path passed via `--config <path>`
2. `~/.config/ctm/config.json`
3. `~/.ctm.json`

Example (`config.example.json`):

```json
{
  "plan": "pro",
  "refresh_interval_seconds": 30,
  "notify_on_reset": true,
  "notify_threshold_percent": 80,

  "email": {
    "enabled": true,
    "smtp_host": "smtp.gmail.com",
    "smtp_port": 465,
    "username": "you@gmail.com",
    "password": "your-app-password",
    "from": "you@gmail.com",
    "to": "notify@youremail.com"
  }
}
```

### Setting up Gmail notifications

1. Enable 2-factor auth on your Google account
2. Create an app password: <https://myaccount.google.com/apppasswords>
3. Paste it into the `password` field above
4. Make sure `enabled: true`

`ctm` uses `curl` for SMTPS — no extra dependencies on Pi OS.

### Plans

| Value   | Plan        | Approx token limit (5h) |
|---------|-------------|-------------------------|
| `pro`   | Pro         | 88,000                  |
| `max5`  | Max 5x      | 440,000                 |
| `max20` | Max 20x     | 1,760,000               |

> Limits are rough — Anthropic doesn't publish exact numbers. Adjust
> `src/config.zig` if your account behaves differently.

---

## Two-machine setup (Pi Zero + dev machine)

This is the primary deployment scenario. Claude Code runs on your dev machine;
the Pi Zero runs `ctm --daemon` and sends emails.

### 1. Pi Zero — install and configure `ctm`

```bash
# On the Pi
git clone https://github.com/GageLawton/Claude-Token-Monitor
cd Claude-Token-Monitor
bash scripts/install.sh          # installs ctm to /usr/local/bin

mkdir -p ~/.config/ctm
cp config.example.json ~/.config/ctm/config.json
# Edit: set your email, shared_secret, and ingest_server.enabled = true
nano ~/.config/ctm/config.json
```

Start the daemon:

```bash
ctm --daemon
# or via systemd (see below)
```

### 2. Dev machine — install and configure `ctm-agent`

```bash
# On your Mac/Linux dev machine
zig build -Doptimize=ReleaseSafe
sudo cp zig-out/bin/ctm-agent /usr/local/bin/

mkdir -p ~/.config/ctm
cp config.example.agent.json ~/.config/ctm/agent.json
# Edit: set pi_host (raspberrypi.local or IP), and the same shared_secret
nano ~/.config/ctm/agent.json
```

Run the agent (keep it running in the background):

```bash
ctm-agent &
# or add to your shell profile / launchd / systemd user session
```

### 3. Verify

```bash
# On dev machine — should see "shipping N new lines"
ctm-agent --help

# On Pi — watch the log
tail -f ~/.ctm.log
```

### Finding your Pi's hostname

Most Pi OS installations advertise as `raspberrypi.local` on the LAN via mDNS.
If that doesn't work, find the IP with `hostname -I` on the Pi and use it directly
in `pi_host`.

### Security note

The shared secret prevents random LAN devices from pushing data to your Pi.
The connection is plain HTTP — it's fine for a home network. If you expose the
Pi to the internet, put it behind a reverse proxy with TLS.

---

## Running as a background service

After `install.sh` runs, enable it:

```bash
sudo systemctl enable --now claude-token-monitor@$USER

# Tail the logs
journalctl -u claude-token-monitor@$USER -f
```

It will auto-start on boot and restart if it crashes.

---

## Development

### Project layout

```
├── src/
│   ├── main.zig            CLI entry point
│   ├── config.zig          JSON config + plan definitions
│   ├── usage_reader.zig    JSONL parser for ~/.claude/projects/
│   ├── session_tracker.zig 5-hour window math, burn rate, summaries
│   ├── dashboard.zig       Live terminal UI
│   ├── email.zig           SMTP notifications
│   ├── daemon.zig          Background daemon mode
│   ├── watcher.zig         inotify + stat-poll file watcher (shared)
│   ├── ingest_state.zig    Thread-safe in-memory entry store
│   ├── ingest_server.zig   HTTP endpoint (Pi receives pushed data)
│   └── agent/
│       ├── main.zig        ctm-agent entry point (dev machine)
│       └── shipper.zig     HTTP POST to Pi ingest endpoint
├── tests/                  Unit tests (one file per source module)
├── systemd/                Service unit template
├── scripts/                Install + coverage helpers
└── build.zig               Zig build & test runner
```

### Running tests

```bash
zig build test
```

### Code coverage

Tests have full coverage of the parsing, window-tracking, and config layers.
For an HTML report, install `kcov` and run:

```bash
sudo apt install kcov
bash scripts/coverage.sh
xdg-open zig-out/coverage/index.html
```

Or directly:

```bash
zig build test -Dcoverage=true
```

What's covered:

| Module               | Tests |
|----------------------|-------|
| `config.zig`         | Default values, JSON parse, missing fields, malformed input |
| `usage_reader.zig`   | ISO-8601 parsing, deduplication, malformed lines, missing dirs |
| `session_tracker.zig`| Window cutoff, plan limits, burn rate, session grouping, reset math |

`dashboard.zig`, `email.zig`, and `daemon.zig` are integration layers (TTY,
network, fork) and are intentionally light on unit tests — they're best
exercised end-to-end by actually running `ctm`.

### Adding a new test

1. Drop a new file in `tests/` (or extend an existing one)
2. Import source modules with `@import("module_name")` — see existing tests
3. If it's a new file, add its path to `test_files` in `build.zig`
4. `zig build test`

---

## How it works

Claude Code writes one JSONL line per assistant turn into
`~/.claude/projects/<project>/<session-uuid>.jsonl`. Each line carries:

```json
{
  "type": "assistant",
  "uuid": "...",
  "sessionId": "...",
  "timestamp": "2024-06-01T10:00:00.000Z",
  "costUSD": 0.05,
  "message": {
    "usage": {
      "input_tokens": 100,
      "output_tokens": 200,
      "cache_creation_input_tokens": 10,
      "cache_read_input_tokens": 5
    }
  }
}
```

`ctm` recursively scans those files, deduplicates by `uuid`, then sums tokens
that fall inside the most recent 5-hour window. The window's reset time is
the oldest in-window entry plus 5 hours. When a previous "at-limit" state
flips back to "under-limit", the daemon fires the reset email.

No API calls, no Claude login, no separate auth — it just reads the same
data the CLI is already producing on disk.

---

## License

[MIT](LICENSE) © Gage Lawton
