# Claude Token Monitor — status

Run the token monitor status check from within Claude Code.

```bash
ctm --status
```

If `ctm` is not installed, build it first:

```bash
cd ~/Claude-Token-Monitor && zig build -Doptimize=ReleaseSafe && sudo cp zig-out/bin/ctm /usr/local/bin/ctm
```
