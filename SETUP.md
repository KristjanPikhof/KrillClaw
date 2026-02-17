# KrillClaw Setup (Ubuntu)

This guide covers:
- Installing Zig on Ubuntu
- Building KrillClaw
- Configuring API keys (Claude/OpenAI/NanoGPT/Ollama)
- Running the Zig-native Telegram bot

---

## 1) Install system prerequisites

```bash
sudo apt update
sudo apt install -y curl xz-utils git ca-certificates build-essential
```

---

## 2) Install Zig (recommended: official tarball)

KrillClaw currently targets modern Zig (use **0.15+**).

### 2.1 Pick a version and architecture

```bash
ZIG_VERSION="0.15.1"
ARCH="$(uname -m)"

if [ "$ARCH" = "x86_64" ]; then
  ZIG_ARCH="x86_64-linux"
elif [ "$ARCH" = "aarch64" ]; then
  ZIG_ARCH="aarch64-linux"
else
  echo "Unsupported arch: $ARCH"
  exit 1
fi
```

### 2.2 Download and install

```bash
cd /tmp
curl -LO "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz"
tar -xf "zig-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz"

sudo rm -rf /opt/zig
sudo mv "zig-${ZIG_ARCH}-${ZIG_VERSION}" /opt/zig
sudo ln -sf /opt/zig/zig /usr/local/bin/zig
```

### 2.3 Verify

```bash
zig version
```

---

## 3) Clone and build KrillClaw

```bash
git clone git@github.com:KristjanPikhof/KrillClaw.git
cd KrillClaw

# release build
zig build -Doptimize=ReleaseSmall

# show produced binaries
ls -la zig-out/bin
```

Expected binaries:
- `yoctoclaw`
- `yoctoclaw-telegram`

> Note: some older docs/examples may still show `krillclaw`. If so, use the actual binary in `zig-out/bin`.

---

## 4) Configure provider + API keys

KrillClaw supports providers:
- `claude`
- `openai`
- `nanogpt`
- `ollama` (no API key required)

### 4.1 Pick one provider

#### Claude
```bash
export ANTHROPIC_API_KEY="<your_key>"
export YOCTOCLAW_PROVIDER="claude"
export YOCTOCLAW_MODEL="claude-sonnet-4-5-20250929"
```

#### OpenAI
```bash
export OPENAI_API_KEY="<your_key>"
export YOCTOCLAW_PROVIDER="openai"
export YOCTOCLAW_MODEL="gpt-4o"
```

#### NanoGPT (OpenAI-compatible)
```bash
export NANO_GPT_API_KEY="<your_key>"
export YOCTOCLAW_PROVIDER="nanogpt"
export YOCTOCLAW_MODEL="openai/gpt-5.2-chat-latest"
```

#### Ollama (local)
```bash
export YOCTOCLAW_PROVIDER="ollama"
export YOCTOCLAW_MODEL="llama3"
```

### 4.2 Optional env vars

```bash
export YOCTOCLAW_BASE_URL="https://your-openai-compatible-endpoint"
export YOCTOCLAW_SYSTEM_PROMPT="You are a careful coding assistant"
export YOCTOCLAW_MAX_TOKENS="4096"
```

---

## 5) Run KrillClaw CLI

Interactive:

```bash
./zig-out/bin/yoctoclaw
```

One-shot:

```bash
./zig-out/bin/yoctoclaw "explain this repository"
```

Provider/model override from CLI:

```bash
./zig-out/bin/yoctoclaw --provider nanogpt -m openai/gpt-5.2-chat-latest "fix failing tests"
```

---

## 6) (Recommended) safer local execution

KrillClaw can run tools like shell/file operations. For safer testing:

```bash
zig build -Dsandbox=true -Doptimize=ReleaseSmall
./zig-out/bin/yoctoclaw
```

Also:
- Don’t run as root
- Don’t keep sensitive credentials in your shell/session while testing

---

## 7) Telegram bot setup (Zig-native)

No Python runtime is required for bot mode.

### 7.1 Create a bot token

1. Open Telegram and message **@BotFather**
2. Run `/newbot`
3. Save the bot token (looks like `123456:ABC-...`)

### 7.2 Get your chat ID(s)

1. Send a message to your new bot (or in your target group)
2. Run:

```bash
export TELEGRAM_BOT_TOKEN="<your_bot_token>"
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates"
```

3. Find `chat.id` in the JSON output (can be negative for groups)

### 7.3 Configure bot env vars

```bash
export TELEGRAM_BOT_TOKEN="<your_bot_token>"
export TELEGRAM_ALLOWED_CHAT_IDS="123456789,-1001234567890"

# provider settings (example: NanoGPT)
export NANO_GPT_API_KEY="<your_key>"
export YOCTOCLAW_PROVIDER="nanogpt"
export YOCTOCLAW_MODEL="openai/gpt-5.2-chat-latest"

# optional
export TELEGRAM_POLL_TIMEOUT="30"
export TELEGRAM_MAX_REPLY_CHARS="4000"
```

### 7.4 Run bot

```bash
./zig-out/bin/yoctoclaw-telegram
```

The bot accepts only chat IDs listed in `TELEGRAM_ALLOWED_CHAT_IDS`.

---

## 8) Optional: systemd service for Telegram bot

Create env file:

```bash
sudo mkdir -p /etc/krillclaw
sudo nano /etc/krillclaw/telegram.env
```

Example `/etc/krillclaw/telegram.env`:

```env
TELEGRAM_BOT_TOKEN=<token>
TELEGRAM_ALLOWED_CHAT_IDS=123456789
NANO_GPT_API_KEY=<key>
YOCTOCLAW_PROVIDER=nanogpt
YOCTOCLAW_MODEL=openai/gpt-5.2-chat-latest
```

Create service file:

```bash
sudo nano /etc/systemd/system/yoctoclaw-telegram.service
```

```ini
[Unit]
Description=YoctoClaw Telegram Bot
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/krillclaw
EnvironmentFile=/etc/krillclaw/telegram.env
ExecStart=/opt/krillclaw/zig-out/bin/yoctoclaw-telegram
Restart=always
RestartSec=3
User=ubuntu
Group=ubuntu

[Install]
WantedBy=multi-user.target
```

Enable/start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable yoctoclaw-telegram
sudo systemctl start yoctoclaw-telegram
sudo systemctl status yoctoclaw-telegram
```

Logs:

```bash
journalctl -u yoctoclaw-telegram -f
```

---

## 9) Troubleshooting

### `zig: command not found`
- Ensure `/usr/local/bin` is in `PATH`
- Re-open shell and run `zig version`

### API key errors
- Claude: set `ANTHROPIC_API_KEY`
- OpenAI: set `OPENAI_API_KEY`
- NanoGPT: set `NANO_GPT_API_KEY`
- Ollama: no key required

### Telegram bot exits immediately
- Missing required vars:
  - `TELEGRAM_BOT_TOKEN`
  - `TELEGRAM_ALLOWED_CHAT_IDS`

### Wrong binary name in older instructions
- Always trust output of:

```bash
ls -la zig-out/bin
```
