# pi-fleet

A Pi extension for managing several Pi sessions in tmux.

## Features

- Names a session from its first prompt.
- Shows the tmux title and status: `🤖` working, `🟢` ready, `🙋` question, `🆕` new.
- Rings the terminal bell when Pi settles.
- Shows an idle recap after four minutes.
- Adds `/ref` to insert a pointer to another local Pi session.
- Preserves a manually renamed tmux window while restoring its status marker.

## Install

```bash
pi install git:github.com/hateonion/pi-fleet@v0.1.0
```

Restart Pi or run `/reload` after installation.

For a temporary test:

```bash
pi -e git:github.com/hateonion/pi-fleet@v0.1.0
```

## Requirements

- [Pi](https://pi.dev)
- tmux for tmux title and bell behaviour

## Privacy and security

Pi extensions run with the installing user's full system permissions. Review the source before installation.

After a session has been idle for four minutes, pi-fleet starts a separate no-tools Pi call to produce a two-line recap. That call receives a truncated excerpt of the last eight messages and uses `opencode-go/deepseek-v4-flash` by default, falling back to `openai-codex/gpt-5.6-luna` if that call fails. Override the model with the `PI_FLEET_RECAP_MODEL` environment variable (single model, no fallback). Disable or modify this behaviour before using pi-fleet in sensitive conversations.

## License

MIT.
