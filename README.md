# pi-fleet

Tools for running several Pi sessions: a Pi extension for tmux fleets, plus a Herdr plugin that auto-names agent panes.

## Pi extension

Manages several Pi sessions in tmux.

## Features

- Names a session from its first prompt.
- Shows the tmux title and status: `🤖` working, `🟢` ready, `🙋` question, `🆕` new.
- Rings the terminal bell when Pi settles.
- Shows an idle recap after four minutes.
- Adds `/ref` to insert a pointer to another local Pi session.
- Preserves a manually renamed tmux window while restoring its status marker.

## Install

```bash
pi install git:github.com/hateonion/pi-fleet@v0.2.0
```

Restart Pi or run `/reload` after installation.

For a temporary test:

```bash
pi -e git:github.com/hateonion/pi-fleet@v0.2.0
```

## Requirements

- [Pi](https://pi.dev)
- tmux for tmux title and bell behaviour

## Privacy and security

Pi extensions run with the installing user's full system permissions. Review the source before installation.

After a session has been idle for four minutes, pi-fleet starts a separate no-tools Pi call to produce a two-line recap. That call receives a truncated excerpt of the last eight messages and uses `opencode-go/deepseek-v4-flash` by default, falling back to `openai-codex/gpt-5.6-luna` if that call fails. Override the model with the `PI_FLEET_RECAP_MODEL` environment variable (single model, no fallback). Disable or modify this behaviour before using pi-fleet in sensitive conversations.

## Herdr auto-rename plugin

Names an unnamed agent pane from its first user question (Pi) or recent pane output (other agents) once the agent settles. The generated name is short: one to three words.

### Install

```bash
herdr plugin install hateonion/pi-fleet/herdr/auto-rename --ref v0.2.0
```

### Model

Renaming calls the configured Pi model `opencode-go/deepseek-v4-flash` by default. Override with the `HERDR_RENAME_MODEL` environment variable, for example:

```bash
export HERDR_RENAME_MODEL="openai-codex/gpt-5.6-luna"
```

### Privacy and security

Herdr plugins run with the installing user's full system permissions. Review the source before installation.

The plugin sends the first user question (Pi sessions) or the most recent pane output (other agents) to the configured Pi model to generate a title. Do not enable the plugin where pane output must not be sent to that model.

## License

MIT.
