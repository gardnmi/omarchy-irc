# Omarchy IRC

Join `#omachee` on Libera.Chat from a native, Omarchy-themed bar panel. Omarchy
IRC uses a bundled, standard-library-only Python helper and does not embed a web
page or browser UI.

## Features

- Native bar icon, connection indicator, and unread count
- Native QML timeline and single-line message composer
- Mouse-selectable message text with standard `Ctrl+C` copying
- Clickable sender names with contextual DM and mute actions
- Unicode emoji display and native Omarchy emoji-picker input
- Channel member selector populated from IRC `NAMES` replies
- Direct-message conversations with individual channel members
- Session-only mute and unmute controls for incoming user messages
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
message from the composer. Select a channel member and choose **DM** to open a
private conversation, or **Mute** to suppress that user's subsequent incoming
messages for the current shell session. **Unmute** restores them. The
conversation selector switches between `#omachee` and opened DMs. **Change**
updates the nickname; **Leave** parts the channel and closes the network
connection.

Drag across any message body to select plain text, then press `Ctrl+C` to copy
the selection. Click another user's nickname in the timeline to reveal **DM**
and **Mute/Unmute** actions directly beneath that message. Clicking the name
again dismisses the actions.

Choose **Emoji** beside the composer to open Omarchy's searchable emoji overlay.
Selecting an emoji inserts it into the focused composer without sending it;
continue typing or press Enter to send. The standard `SUPER+CTRL+E` Omarchy
shortcut opens the same picker. Received Unicode emoji use the system emoji font
fallback, normally `Noto Color Emoji` on Omarchy.

Kiwi IRC's optional emoticon renderer sends ASCII tokens over IRC and replaces
them with emoji only inside Kiwi. For compatibility, the panel applies the same
display-only conversion to common whitespace-delimited tokens, including
`8)` to `😎`, `:)` to `🙂`, and `<3` to `❤`. The raw IRC text remains unchanged
in the session timeline and is never rewritten before protocol handling.

URLs remain plain text in the initial release. The panel does not automatically
open, fetch, preview, or execute links or message content.

## Connection And Privacy

The bundled `irc_helper.py` connects directly to the fixed host
`irc.libera.chat:6697` with Python's default verified TLS trust store. It sends
the selected nickname, a generic IRC user description, channel messages, and
protocol traffic required to join and remain connected to `#omachee`.

The helper starts only after the panel is opened for the first time. It remains
connected while Omarchy shell runs, including while the panel is closed. QML and
the helper communicate through newline-delimited JSON on local process pipes.
The plugin does not write chat history, nicknames, credentials, or connection
state to disk. Direct-message conversations and the muted-user set also remain
only in QML memory. Restarting Omarchy shell discards all of them. Muting is a
local presentation action: Libera still delivers the traffic, but the panel
does not retain or display subsequent messages from that nickname.

There are no account passwords, SASL credentials, analytics, telemetry, public
logs, bots, bridges, embedded browsers, or LLM processing. Libera.Chat and other
channel participants receive normal IRC traffic; consult Libera.Chat's policies
before use.

## Protocol Boundary

Commands sent to the helper include:

```json
{"command":"connect","nickname":"OmarchyUser42"}
{"command":"send","target":"#omachee","text":"Hello from Omarchy"}
{"command":"send","target":"someone","text":"Hello privately"}
```

Events returned to QML include:

```json
{"event":"message","nick":"someone","target":"#omachee","text":"Welcome!"}
{"event":"message","nick":"someone","target":"someone","text":"Private hello"}
{"event":"names","channel":"#omachee","users":["someone","another-user"]}
{"event":"connected","channel":"#omachee","network":"Libera.Chat"}
{"event":"error","message":"Nickname already in use"}
```

The helper handles the IRC messages needed for `JOIN`, channel and direct
`PRIVMSG`, `NOTICE`, `NICK`, `PART`, `QUIT`, `PING`, `NAMES`, channel names, and
connection numerics. Direct-message targets must pass the same nickname
validation as the local guest nickname. Malformed IPC and IRC lines are rejected
or ignored without evaluating their contents.

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
nickname collisions, emoji Unicode, member-list parsing, and direct-message routing without
connecting to Libera.Chat. A release smoke test should use disposable nicknames
to verify connect, join, channel and direct sends, mute/unmute, part, reconnect,
unread state, shell restart, responsive layout, and plugin removal.

## License

[MIT](LICENSE)
