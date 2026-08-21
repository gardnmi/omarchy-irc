#!/usr/bin/env python3
"""Small, session-only IRC client with newline-delimited JSON IPC."""

from __future__ import annotations

import asyncio
import json
import random
import re
import ssl
import sys
from dataclasses import dataclass
from typing import Any

HOST = "irc.libera.chat"
PORT = 6697
CHANNEL = "#omachee"
MAX_IRC_BYTES = 510  # Excludes the required CRLF terminator.
NICK_RE = re.compile(r"^[A-Za-z\[\]\\`_^{|}][A-Za-z0-9\[\]\\`_^{|}-]{0,15}$")


@dataclass(frozen=True)
class IrcMessage:
    prefix: str | None
    command: str
    params: tuple[str, ...]


def parse_irc_line(line: str) -> IrcMessage:
    """Parse one IRC line without interpreting message contents."""
    value = line.rstrip("\r\n")
    if not value or "\x00" in value:
        raise ValueError("invalid IRC line")
    prefix = None
    if value.startswith(":"):
        try:
            prefix, value = value[1:].split(" ", 1)
        except ValueError as error:
            raise ValueError("prefix without command") from error
    trailing = None
    marker = value.find(" :")
    if marker >= 0:
        value, trailing = value[:marker], value[marker + 2 :]
    parts = value.split()
    if not parts:
        raise ValueError("missing IRC command")
    params = parts[1:]
    if trailing is not None:
        params.append(trailing)
    return IrcMessage(prefix, parts[0].upper(), tuple(params))


def nick_from_prefix(prefix: str | None) -> str:
    return (prefix or "").split("!", 1)[0]


def encode_irc(command: str) -> bytes:
    if "\r" in command or "\n" in command or "\x00" in command:
        raise ValueError("IRC command contains a forbidden character")
    encoded = command.encode("utf-8")
    if len(encoded) > MAX_IRC_BYTES:
        raise ValueError("IRC message is too long")
    return encoded + b"\r\n"


def validate_nickname(value: Any) -> str:
    nickname = str(value or "").strip()
    if not NICK_RE.fullmatch(nickname):
        raise ValueError("Use 1-16 letters, numbers, or IRC nickname symbols")
    return nickname


def decode_client_command(line: str) -> dict[str, Any]:
    try:
        payload = json.loads(line)
    except json.JSONDecodeError as error:
        raise ValueError("Malformed JSON command") from error
    if not isinstance(payload, dict) or not isinstance(payload.get("command"), str):
        raise ValueError("Command must be a JSON object with a command field")
    return payload


class IrcClient:
    def __init__(self) -> None:
        self.nickname = ""
        self.requested_nickname = ""
        self.reader: asyncio.StreamReader | None = None
        self.writer: asyncio.StreamWriter | None = None
        self.connection_task: asyncio.Task[None] | None = None
        self.outgoing: asyncio.Queue[str] = asyncio.Queue(maxsize=8)
        self.want_connection = False
        self.joined = False

    def emit(self, event: str, **fields: Any) -> None:
        print(json.dumps({"event": event, **fields}, ensure_ascii=False), flush=True)

    async def command_loop(self) -> None:
        while line := await asyncio.to_thread(sys.stdin.readline):
            try:
                payload = decode_client_command(line)
                await self.handle_command(payload)
            except ValueError as error:
                self.emit("error", message=str(error))
            except Exception:
                self.emit("error", message="Could not process the panel command")
        self.want_connection = False
        await self.disconnect("Shell closed")

    async def handle_command(self, payload: dict[str, Any]) -> None:
        command = payload["command"]
        if command == "connect":
            nickname = validate_nickname(payload.get("nickname"))
            self.requested_nickname = nickname
            self.nickname = nickname
            self.want_connection = True
            if self.connection_task is None or self.connection_task.done():
                self.connection_task = asyncio.create_task(self.connection_loop())
            elif self.writer is not None:
                await self.queue_line(f"NICK {nickname}")
        elif command == "nickname":
            nickname = validate_nickname(payload.get("nickname"))
            self.requested_nickname = nickname
            if self.writer is None:
                self.nickname = nickname
            else:
                await self.queue_line(f"NICK {nickname}")
        elif command == "send":
            text = str(payload.get("text") or "")
            if not self.joined:
                raise ValueError("Join #omachee before sending")
            if not text.strip():
                raise ValueError("Message cannot be empty")
            encode_irc(f"PRIVMSG {CHANNEL} :{text}")
            await self.queue_line(f"PRIVMSG {CHANNEL} :{text}")
            self.emit("message", nick=self.nickname, text=text, own=True)
        elif command == "part":
            self.want_connection = False
            if self.writer is not None:
                await self.write_immediately(f"PART {CHANNEL} :Leaving Omarchy IRC")
            await self.disconnect("Left #omachee")
            self.emit("disconnected", message="Left #omachee")
        else:
            raise ValueError(f"Unsupported command: {command}")

    async def queue_line(self, line: str) -> None:
        encode_irc(line)
        try:
            self.outgoing.put_nowait(line)
        except asyncio.QueueFull as error:
            raise ValueError("Please wait before sending more messages") from error

    async def write_immediately(self, line: str) -> None:
        if self.writer is None:
            return
        self.writer.write(encode_irc(line))
        await self.writer.drain()

    async def connection_loop(self) -> None:
        delay = 1.0
        while self.want_connection:
            try:
                self.emit("status", state="connecting", message=f"Connecting to {HOST}")
                context = ssl.create_default_context()
                self.reader, self.writer = await asyncio.open_connection(
                    HOST, PORT, ssl=context, server_hostname=HOST
                )
                self.joined = False
                self.emit("status", state="authenticating", message="TLS verified")
                await self.write_immediately(f"NICK {self.nickname}")
                await self.write_immediately(
                    f"USER {self.nickname} 0 * :Omarchy IRC guest"
                )
                sender = asyncio.create_task(self.sender_loop())
                try:
                    await self.read_loop()
                finally:
                    sender.cancel()
                    await asyncio.gather(sender, return_exceptions=True)
                delay = 1.0
            except asyncio.CancelledError:
                raise
            except (OSError, ssl.SSLError, asyncio.IncompleteReadError):
                if self.want_connection:
                    self.emit(
                        "status",
                        state="reconnecting",
                        message=f"Connection lost; retrying in {int(delay)}s",
                    )
            finally:
                await self.disconnect(None)
            if self.want_connection:
                await asyncio.sleep(delay + random.uniform(0, delay / 4))
                delay = min(delay * 2, 60.0)

    async def sender_loop(self) -> None:
        while True:
            line = await self.outgoing.get()
            await self.write_immediately(line)
            await asyncio.sleep(1.0)

    async def read_loop(self) -> None:
        assert self.reader is not None
        while self.want_connection:
            raw = await self.reader.readline()
            if not raw:
                raise asyncio.IncompleteReadError(raw, None)
            if len(raw) > 4096:
                continue
            try:
                message = parse_irc_line(raw.decode("utf-8", errors="replace"))
            except ValueError:
                continue
            await self.handle_irc(message)

    async def handle_irc(self, message: IrcMessage) -> None:
        command = message.command
        params = message.params
        source_nick = nick_from_prefix(message.prefix)
        if command == "PING" and params:
            await self.write_immediately(f"PONG :{params[-1]}")
        elif command == "001":
            if params and params[0] != self.nickname:
                self.nickname = params[0]
                self.emit(
                    "nickname",
                    nickname=self.nickname,
                    message=f"Server confirmed nickname {self.nickname}",
                )
            await self.queue_line(f"JOIN {CHANNEL}")
        elif command == "433":
            self.nickname = (self.requested_nickname[:13] + "_" + str(random.randint(10, 99)))[:16]
            await self.write_immediately(f"NICK {self.nickname}")
            self.emit(
                "nickname",
                nickname=self.nickname,
                message="Nickname was in use; selected a guest variant",
            )
        elif command == "JOIN" and params:
            channel = params[-1]
            if source_nick == self.nickname and channel.lower() == CHANNEL:
                self.joined = True
                self.emit("connected", channel=CHANNEL, network="Libera.Chat", nickname=self.nickname)
            else:
                self.emit("join", nick=source_nick, channel=channel)
        elif command == "PRIVMSG" and len(params) >= 2 and params[0].lower() == CHANNEL:
            text = params[1]
            if text.startswith("\x01ACTION ") and text.endswith("\x01"):
                self.emit("action", nick=source_nick, text=text[8:-1])
            elif not text.startswith("\x01"):
                self.emit("message", nick=source_nick, text=text, own=False)
        elif command == "NOTICE" and params:
            text = params[-1]
            if not text.startswith("\x01"):
                self.emit("notice", nick=source_nick, text=text)
        elif command == "NICK" and params:
            new_nick = params[-1]
            if source_nick == self.nickname:
                self.nickname = new_nick
                self.emit("nickname", nickname=new_nick, message=f"You are now {new_nick}")
            else:
                self.emit("nick", nick=source_nick, newNick=new_nick)
        elif command == "PART" and params:
            self.emit("part", nick=source_nick, channel=params[0])
        elif command == "QUIT":
            self.emit("quit", nick=source_nick, message=params[-1] if params else "")
        elif command.isdigit() and command[0] in "45" and params:
            self.emit("error", message=params[-1])

    async def disconnect(self, _reason: str | None) -> None:
        self.joined = False
        writer, self.writer = self.writer, None
        self.reader = None
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except (OSError, ssl.SSLError):
                pass


async def main() -> None:
    await IrcClient().command_loop()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
