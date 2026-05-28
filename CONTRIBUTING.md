# Contributing to Claude Token Monitor

Thanks for taking the time to contribute! This document covers the practical steps to get your change from idea to merged PR.

## Getting started

1. **Fork** the repository and clone your fork.
2. Create a branch: `git checkout -b feat/your-feature` or `fix/your-bug`.
3. Make your changes and add tests.
4. Open a pull request against `main`.

## Development requirements

- [Zig 0.13.0](https://ziglang.org/download/) — the only toolchain you need.
- Linux recommended for the full test suite (inotify tests only run on Linux). macOS works for most things.
- `kcov` (optional) for code-coverage reports.

## Running tests

```bash
zig build test
```

All tests must pass before a PR can merge.

## Code style

- Standard Zig formatting: run `zig fmt src/ tests/` before committing.
- Allocator discipline: prefer arena allocators for request-scoped data; always pair `init` with `deinit`.
- Keep Pi Zero in mind: avoid `readToEndAlloc` on unbounded files, avoid excessive allocations in hot loops, and test that new code doesn't regress RSS under load.
- No comments that describe *what* the code does — names should do that. Comments are for non-obvious *why*: workarounds, invariants, hardware constraints.

## Commit messages

Use the imperative mood, 72-char subject line:

```
fix: reject assistant entries without a uuid

Prevents a nil-pointer deref when processing JSONL written by older
versions of the Claude CLI that omit the uuid field.
```

Prefix with `fix:`, `feat:`, `refactor:`, `test:`, `docs:`, or `ci:`.

## Reporting a bug

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Include the output of `uname -m` and `zig version` — the Pi Zero's ARMv6 core is the primary deployment target, so architecture matters.

## Suggesting a feature

Use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.md). Each issue is scoped to roughly 15 minutes of implementation work — if your idea is larger, break it into smaller issues.

## Pi Zero constraints

The Pi Zero W has:
- **512 MB RAM** shared with the OS and other processes
- **Single ARM11 core** at 1 GHz (ARMv6)
- `ctm` is expected to idle at **< 1% CPU** and **< 8 MB RSS**

Any change that regresses these numbers needs a documented justification.

## License

By contributing, you agree that your contribution will be licensed under the [MIT License](LICENSE).
