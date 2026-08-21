# Omarchy IRC Development Guide

This repository is a native Omarchy Quattro bar plugin for session-only IRC
chat in `#omachee` on Libera.Chat.

The permanent plugin ID is `io.github.gardnmi.omarchy-irc`. Never change it.

## Runtime Contract

- `Panel.qml` owns UI state, unread state, and the in-memory timeline.
- `irc_helper.py` owns verified TLS and IRC protocol behavior.
- IPC is newline-delimited JSON over the helper's stdin and stdout.
- The helper starts on first panel open and remains alive with Omarchy shell.
- Never persist messages, nicknames, credentials, or connection state.
- Direct-message conversations and muted nicknames are QML session state only.
- Muting suppresses subsequent incoming messages locally; it is not an IRC ban
  and must not be presented as preventing network delivery.
- Render all remote content with `Text.PlainText`; never evaluate it.
- Message bodies are read-only plain-text editors so users can select and copy
  text. Sender names are separate controls that reveal scoped DM and mute
  actions; never make remote message text itself executable.
- Preserve Unicode emoji end to end and use Omarchy's existing `omarchy.emojis`
  overlay for input rather than bundling another picker or emoji dataset.
- Kiwi IRC sends ASCII emoticon tokens and substitutes emoji only while
  rendering. Keep compatibility substitutions bounded, display-only, and
  whitespace-delimited; never mutate protocol text or convert arbitrary prose.
- Keep the server fixed to `irc.libera.chat:6697` and channel fixed to `#omachee`.
- Do not add passwords, SASL, telemetry, bots, bridges, or LLM processing.
- Do not expose channel operator actions such as access changes, kick, or ban
  without an explicit future requirement and confirmation design.
- Preserve IRC line limits, flood throttling, PING/PONG, reconnect backoff, and
  nickname collision handling.

## Validation

```bash
omarchy plugin validate .
qmllint -I /usr/share/omarchy/shell Panel.qml
bash -n deploy-local.sh
python3 -m unittest discover -s tests -v
git diff --check
```

Live network testing must use a disposable guest nickname and avoid publishing
private content. Verify connect, join, send, part, reconnect, unread state, shell
restart, panel responsiveness, and removal.
