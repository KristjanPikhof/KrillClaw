# Contributing to KrillClaw

Thank you for your interest in contributing to KrillClaw! This document provides guidelines for contributing.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/KrillClaw.git`
3. Create a feature branch: `git checkout -b feature/your-feature`
4. Install Zig 0.13+ from https://ziglang.org/download/

## Building

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseSmall

# Run tests
zig build test
```

## Code Style

- Follow Zig standard library conventions
- Run `zig fmt` before committing
- Keep functions small and focused
- Add inline tests for new functionality

## Pull Request Process

1. Ensure your code builds cleanly: `zig build`
2. Ensure all tests pass: `zig build test`
3. Ensure the release binary stays under 300KB: `zig build -Doptimize=ReleaseSmall`
4. Update documentation if you changed behavior
5. Write a clear PR description explaining the change and motivation
6. Link any related issues

## Binary Size Policy

KrillClaw's identity is being tiny. PRs that significantly increase binary size need strong justification. The CI gate enforces a 300KB limit on the release binary.

## Reporting Bugs

Use the [bug report template](https://github.com/krillclaw/KrillClaw/issues/new?template=bug_report.md).

## Suggesting Features

Use the [feature request template](https://github.com/krillclaw/KrillClaw/issues/new?template=feature_request.md).

## Security Issues

Please report security vulnerabilities privately. See [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions will be licensed under the BSL 1.1, converting to Apache 2.0 after 4 years per the project license terms.
