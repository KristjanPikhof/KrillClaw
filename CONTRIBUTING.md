# Contributing to KrillClaw

Thanks for your interest in contributing to KrillClaw! Here's how to get started.

## Getting Started

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Run the tests (`zig build test`)
5. Commit your changes (`git commit -m 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## Development Setup

- Install [Zig 0.15+](https://ziglang.org/download/)
- Clone the repo: `git clone https://github.com/krillclaw/KrillClaw.git`
- Build: `zig build`
- Test: `zig build test`
- Release build: `zig build -Doptimize=ReleaseSmall`

## Code Style

- Follow standard Zig conventions
- Keep functions small and focused
- Add tests for new functionality
- Document public APIs

## Reporting Bugs

Use [GitHub Issues](https://github.com/krillclaw/KrillClaw/issues) with the bug report template.

## License

By contributing, you agree that your contributions will be licensed under the project's BSL 1.1 license.
