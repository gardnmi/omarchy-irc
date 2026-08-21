# Omarchy IRC

Join `#omarchy` on Libera.Chat from a native, Omarchy-themed bar panel. Omarchy
IRC uses a bundled, standard-library-only Python helper and does not embed a web
page or browser UI.

## Features

- Native bar icon, connection indicator, and unread count
- Native QML timeline and single-line message composer
- User-selected 1-16 character guest nickname with collision handling and in-panel changes
- Verified TLS connection to `irc.libera.chat:6697`
- Automatic PING/PONG and bounded exponential reconnect backoff
- Session-only messages that disappear when Omarchy shell restarts
- Plain-text rendering for messages and notices
- Outgoing IRC line-limit checks and one-message-per-second throttling
- Compact join, part, quit, nickname, and connection notices
- `/me` actions rendered as plain text; other CTCP commands ignored

## Requirements

- Omarchy with the Quattro shell plugin system
- Python 3 available on `PATH`
- Network access to `irc.libera.chat` on TCP port `6697`

## Install

Review the source before installing. Omarchy plugins run as unsandboxed code
inside the long-running shell process, and this plugin starts its bundled Python
helper on first panel open.

```bash
omarchy plugin add https://github.com/gardnmi/omarchy-irc.git --enable
```

If needed, enable it later:

```bash
omarchy plugin enable io.github.gardnmi.omarchy-irc --section right
```

Open the chat icon, choose a guest nickname, and select **Join**. Enter sends a
message from the composer. **Change** updates the nickname; **Leave** parts the
channel and closes the network connection.

URLs remain plain text in the initial release. The panel does not automatically
open, fetch, preview, or execute links or message content.

## Connection And Privacy

The bundled `irc_helper.py` connects directly to the fixed host
`irc.libera.chat:6697` with Python's default verified TLS trust store. It sends
the selected nickname, a generic IRC user description, channel messages, and
protocol traffic required to join and remain connected to `#omarchy`.

The helper starts only after the panel is opened for the first time. It remains
connected while Omarchy shell runs, including while the panel is closed. QML and
the helper communicate through newline-delimited JSON on local process pipes.
The plugin does not write chat history, nicknames, credentials, or connection
state to disk. Restarting Omarchy shell discards the timeline.

There are no account passwords, SASL credentials, analytics, telemetry, public
logs, bots, bridges, embedded browsers, or LLM processing. Libera.Chat and other
channel participants receive normal IRC traffic; consult Libera.Chat's policies
before use.

## Protocol Boundary

Commands sent to the helper include:

```json
{"command":"connect","nickname":"OmarchyUser42"}
{"command":"send","text":"Hello from Omarchy"}
```

Events returned to QML include:

```json
{"event":"message","nick":"someone","text":"Welcome!"}
{"event":"connected","channel":"#omarchy","network":"Libera.Chat"}
{"event":"error","message":"Nickname already in use"}
```

The helper handles the IRC messages needed for `JOIN`, `PRIVMSG`, `NOTICE`,
`NICK`, `PART`, `QUIT`, `PING`, channel names, and connection numerics. Malformed
IPC and IRC lines are rejected or ignored without evaluating their contents.

## Update And Remove

```bash
omarchy plugin update io.github.gardnmi.omarchy-irc
omarchy plugin remove io.github.gardnmi.omarchy-irc
```

Removing the plugin stops its helper when Omarchy reloads the plugin. No history
or credentials remain to remove.

## Development

```bash
mise run test
mise run validate
mise run restart
omarchy-shell io.github.gardnmi.omarchy-irc open
```

The tests exercise IRC parsing, malformed input, Unicode, line limits, JSON IPC,
and nickname collisions without connecting to Libera.Chat. A release smoke test
should use a disposable nickname to verify connect, join, send, part, reconnect,
unread state, shell restart, responsive layout, and plugin removal.

## License

[MIT](LICENSE)
