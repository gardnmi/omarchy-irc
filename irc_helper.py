#!/usr/bin/env python3
"""Small IRC client with newline-delimited JSON IPC and optional keyring login."""

from __future__ import annotations

import asyncio
import base64
from datetime import datetime, timezone
import json
import os
import random
import re
import ssl
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

HOST = "irc.libera.chat"
PORT = 6697
CHANNEL = "#omachee"
SASL_TIMEOUT_SECONDS = 20
MAX_IRC_BYTES = 510  # Excludes the required CRLF terminator.
NICK_RE = re.compile(r"^[A-Za-z\[\]\\`_^{|}][A-Za-z0-9\[\]\\`_^{|}-]{0,15}$")
ACCOUNT_RE = re.compile(r"^[A-Za-z0-9\[\]\\`_^{|}-]{1,16}$")
KEYRING_ATTRIBUTE = "application"
KEYRING_VALUE = "io.github.gardnmi.omarchy-irc"
SECRET_TOOL = "/usr/bin/secret-tool"
HISTORY_LIMIT = 100
HISTORY_VERSION = 1
MAX_HISTORY_BYTES = 1024 * 1024


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


def nick_key(value: str) -> str:
    return value.lower().translate(str.maketrans("[]\\^", "{}|~"))


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


def validate_message_target(value: Any) -> str:
    target = str(value or CHANNEL).strip()
    if target.lower() == CHANNEL:
        return CHANNEL
    return validate_nickname(target)


def validate_password(value: Any) -> str:
    password = str(value or "")
    if not password:
        raise ValueError("Enter the NickServ password")
    if "\x00" in password or len(password) > 1024:
        raise ValueError("NickServ password is invalid")
    return password


def validate_reason(value: Any, default: str) -> str:
    reason = str(value or default).strip()
    if not reason:
        reason = default
    if any(character in reason for character in "\r\n\x00"):
        raise ValueError("Moderation reason contains a forbidden character")
    if len(reason.encode("utf-8")) > 240:
        raise ValueError("Moderation reason is too long")
    return reason


def sasl_plain_chunks(account: str, password: str) -> list[str]:
    payload = base64.b64encode(f"\0{account}\0{password}".encode()).decode("ascii")
    chunks = [payload[index:index + 400] for index in range(0, len(payload), 400)]
    if len(payload) % 400 == 0:
        chunks.append("+")
    return chunks


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
        self.sasl_account = ""
        self.sasl_password = ""
        self.authenticated = False
        self.sasl_deadline: float | None = None
        self.available_capabilities: set[str] = set()
        self.reader: asyncio.StreamReader | None = None
        self.writer: asyncio.StreamWriter | None = None
        self.connection_task: asyncio.Task[None] | None = None
        self.outgoing: asyncio.Queue[str] = asyncio.Queue(maxsize=8)
        self.want_connection = False
        self.joined = False
        self.pending_names: list[str] = []
        self.pending_name_keys: set[str] = set()
        self.pending_name_exclusions: set[str] = set()
        self.pending_operators: set[str] = set()
        self.collecting_names = False
        self.members: dict[str, str] = {}
        self.operators: set[str] = set()
        self.pending_bans: dict[str, tuple[str, str]] = {}
        self.send_lock = asyncio.Lock()
        self.last_send_time = 0.0
        self.background_tasks: set[asyncio.Task[None]] = set()
        self.remember_login = False
        state_home = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
        self.history_path = state_home / "omarchy-irc/history.json"

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
            password = str(payload.get("password") or "")
            account = validate_nickname(payload.get("account") or nickname) if password else ""
            self.requested_nickname = nickname
            self.nickname = nickname
            self.sasl_account = account
            self.sasl_password = validate_password(password) if password else ""
            self.remember_login = bool(password and payload.get("remember"))
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
            target = validate_message_target(payload.get("target"))
            if not self.joined:
                raise ValueError("Join #omachee before sending")
            if not text.strip():
                raise ValueError("Message cannot be empty")
            if "\x01" in text:
                raise ValueError("Message contains a forbidden control character")
            encode_irc(f"PRIVMSG {target} :{text}")
            await self.queue_line(f"PRIVMSG {target} :{text}")
            self.emit("message", nick=self.nickname, target=target, text=text, own=True)
        elif command == "action":
            text = str(payload.get("text") or "")
            target = validate_message_target(payload.get("target"))
            if not self.joined:
                raise ValueError("Join #omachee before sending")
            if not text.strip():
                raise ValueError("Action cannot be empty")
            if "\x01" in text:
                raise ValueError("Action contains a forbidden control character")
            await self.queue_line(f"PRIVMSG {target} :\x01ACTION {text}\x01")
            self.emit("action", nick=self.nickname, target=target, text=text, own=True)
        elif command == "request_operator":
            if not self.joined or not self.authenticated:
                raise ValueError("NickServ login is required to request operator status")
            await self.queue_line(f"PRIVMSG ChanServ :OP {CHANNEL}")
        elif command == "drop_operator":
            self.require_operator()
            await self.queue_line(f"MODE {CHANNEL} -o {self.nickname}")
        elif command in {"kick", "ban"}:
            self.require_operator()
            target = self.require_member(payload.get("nickname"))
            default_reason = "Removed by a channel operator" if command == "kick" \
                else "Banned by a channel operator"
            reason = validate_reason(payload.get("reason"), default_reason)
            if command == "kick":
                async with self.send_lock:
                    await self.wait_for_send_slot()
                    self.require_operator()
                    target = self.require_member(target)
                    await self.write_batch_immediately(
                        [f"KICK {CHANNEL} {target} :{reason}"]
                    )
                    self.last_send_time = asyncio.get_running_loop().time()
            else:
                self.pending_bans[nick_key(target)] = (target, reason)
                await self.queue_line(f"WHOIS {target}")
        elif command == "part":
            self.want_connection = False
            self.sasl_account = ""
            self.sasl_password = ""
            self.authenticated = False
            if self.writer is not None:
                await self.write_immediately(f"PART {CHANNEL} :Leaving Omarchy IRC")
            await self.disconnect("Left #omachee")
            self.emit("disconnected", message="Left #omachee")
        elif command == "clear_saved_login":
            await self.clear_saved_login()
        elif command == "store_history":
            await asyncio.to_thread(self.store_history, payload)
        elif command == "clear_history":
            await asyncio.to_thread(self.clear_history)
        else:
            raise ValueError(f"Unsupported command: {command}")

    def load_history(self) -> list[dict[str, Any]]:
        try:
            if self.history_path.stat().st_size > MAX_HISTORY_BYTES:
                return []
            document = json.loads(self.history_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            return []
        if not isinstance(document, dict) or document.get("version") != HISTORY_VERSION:
            return []
        messages = document.get("messages")
        if not isinstance(messages, list):
            return []
        valid = [message for message in messages if self.valid_history_event(message)]
        return valid[-HISTORY_LIMIT:]

    @staticmethod
    def valid_history_event(event: Any) -> bool:
        if not (
            isinstance(event, dict)
            and event.get("kind") in {"message", "action"}
            and isinstance(event.get("nick"), str)
            and len(event["nick"]) <= 64
            and isinstance(event.get("text"), str)
            and isinstance(event.get("own"), bool)
            and isinstance(event.get("timestamp"), str)
            and len(event["timestamp"]) <= 64
        ):
            return False
        try:
            event["nick"].encode("utf-8")
            text_size = len(event["text"].encode("utf-8"))
            datetime.fromisoformat(event["timestamp"])
        except (UnicodeEncodeError, ValueError):
            return False
        return text_size <= 4096

    def store_history(self, payload: dict[str, Any]) -> None:
        event = {
            "kind": payload.get("kind"),
            "nick": payload.get("nick"),
            "text": payload.get("text"),
            "own": payload.get("own"),
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        if not self.valid_history_event(event):
            raise ValueError("Invalid channel history event")
        messages = self.load_history()
        messages.append(event)
        self.write_history(messages[-HISTORY_LIMIT:])

    def write_history(self, messages: list[dict[str, Any]]) -> None:
        self.history_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.history_path.parent, 0o700)
        document = json.dumps(
            {"version": HISTORY_VERSION, "messages": messages},
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=".history-", suffix=".tmp", dir=self.history_path.parent
        )
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(document)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.history_path)
        except Exception:
            temporary.unlink(missing_ok=True)
            raise
        os.chmod(self.history_path, 0o600)

    def clear_history(self) -> None:
        self.history_path.unlink(missing_ok=True)
        for temporary in self.history_path.parent.glob(".history-*.tmp"):
            temporary.unlink(missing_ok=True)

    async def keyring_command(self, action: str, secret: bytes | None = None) -> bytes | None:
        arguments = [SECRET_TOOL, action]
        if action == "store":
            arguments.append("--label=Omarchy IRC NickServ login")
        arguments.extend([KEYRING_ATTRIBUTE, KEYRING_VALUE])
        try:
            process = await asyncio.create_subprocess_exec(
                *arguments,
                stdin=asyncio.subprocess.PIPE if secret is not None else asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
        except OSError:
            return None
        try:
            stdout, _ = await asyncio.wait_for(process.communicate(secret), timeout=30)
        except TimeoutError:
            process.kill()
            await process.wait()
            return None
        return stdout.rstrip(b"\r\n") if process.returncode == 0 else None

    async def load_saved_login(self) -> None:
        saved = await self.keyring_command("lookup")
        if not saved:
            return
        try:
            credential = json.loads(saved.decode("utf-8"))
            account = validate_nickname(credential.get("account"))
            password = validate_password(credential.get("password"))
        except (AttributeError, UnicodeDecodeError, json.JSONDecodeError, ValueError):
            await self.clear_saved_login()
            return
        self.emit("saved_login", saved=True, account=account)
        await self.handle_command({
            "command": "connect",
            "nickname": account,
            "account": account,
            "password": password,
            "remember": True,
        })

    async def store_saved_login(self) -> None:
        credential = json.dumps({
            "account": self.sasl_account,
            "password": self.sasl_password,
        }, ensure_ascii=False).encode("utf-8")
        stored = await self.keyring_command("store", credential)
        if stored is None:
            self.emit("error", message="Could not save the NickServ login in the system keyring")
            return
        self.emit("saved_login", saved=True, account=self.sasl_account)

    async def clear_saved_login(self) -> None:
        cleared = await self.keyring_command("clear")
        if cleared is None:
            self.emit("error", message="Could not remove the NickServ login from the system keyring")
            return
        self.remember_login = False
        self.emit("saved_login", saved=False, account="")

    def require_operator(self) -> None:
        if not self.joined or nick_key(self.nickname) not in self.operators:
            raise ValueError("Channel operator status is required")

    def require_member(self, value: Any) -> str:
        nickname = validate_nickname(value)
        key = nick_key(nickname)
        if key == nick_key(self.nickname):
            raise ValueError("You cannot moderate your own connection")
        if key not in self.members:
            raise ValueError("That nickname is no longer in #omachee")
        return self.members[key]

    async def queue_line(self, line: str) -> None:
        encode_irc(line)
        try:
            self.outgoing.put_nowait(line)
        except asyncio.QueueFull as error:
            raise ValueError("Please wait before sending more messages") from error

    async def select_guest_variant(self, message: str) -> None:
        self.nickname = (self.requested_nickname[:13] + "_" + str(random.randint(10, 99)))[:16]
        await self.write_immediately(f"NICK {self.nickname}")
        self.emit("nickname", nickname=self.nickname, message=message)

    async def write_immediately(self, line: str) -> None:
        if self.writer is None:
            return
        self.writer.write(encode_irc(line))
        await self.writer.drain()

    async def write_batch_immediately(self, lines: list[str]) -> None:
        encoded = b"".join(encode_irc(line) for line in lines)
        if self.writer is None:
            raise ValueError("IRC connection is unavailable")
        self.writer.write(encoded)
        await self.writer.drain()

    async def wait_for_send_slot(self) -> None:
        elapsed = asyncio.get_running_loop().time() - self.last_send_time
        if elapsed < 1.0:
            await asyncio.sleep(1.0 - elapsed)

    def schedule_background(self, coroutine: Any) -> None:
        task = asyncio.create_task(coroutine)
        self.background_tasks.add(task)
        task.add_done_callback(self.background_task_done)

    def background_task_done(self, task: asyncio.Task[None]) -> None:
        self.background_tasks.discard(task)
        if task.cancelled():
            return
        if task.exception() is not None:
            self.emit("error", message="Could not complete the moderation action")

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
                self.pending_names = []
                self.pending_name_keys = set()
                self.pending_name_exclusions = set()
                self.pending_operators = set()
                self.collecting_names = False
                self.members = {}
                self.operators = set()
                self.pending_bans = {}
                self.authenticated = False
                self.sasl_deadline = None
                self.available_capabilities = set()
                if self.sasl_account:
                    self.sasl_deadline = (
                        asyncio.get_running_loop().time() + SASL_TIMEOUT_SECONDS
                    )
                    self.emit(
                        "status",
                        state="authenticating",
                        message="TLS verified; identifying with NickServ",
                    )
                    await self.write_immediately("CAP LS 302")
                else:
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
            async with self.send_lock:
                await self.wait_for_send_slot()
                await self.write_immediately(line)
                self.last_send_time = asyncio.get_running_loop().time()

    async def read_loop(self) -> None:
        assert self.reader is not None
        while self.want_connection:
            try:
                if self.sasl_account and not self.authenticated:
                    deadline = self.sasl_deadline or asyncio.get_running_loop().time()
                    remaining = deadline - asyncio.get_running_loop().time()
                    if remaining <= 0:
                        raise TimeoutError
                    raw = await asyncio.wait_for(
                        self.reader.readline(), timeout=remaining
                    )
                else:
                    raw = await self.reader.readline()
            except TimeoutError:
                await self.fail_authentication("authentication timed out")
                return
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
        elif command == "CAP" and self.sasl_account:
            subcommand = next((value.upper() for value in params
                               if value.upper() in {"LS", "ACK", "NAK"}), "")
            if subcommand == "LS":
                self.available_capabilities.update(
                    capability.split("=", 1)[0] for capability in params[-1].split()
                )
                continuing = len(params) >= 3 and params[-2] == "*"
                if not continuing:
                    if "sasl" not in self.available_capabilities:
                        await self.fail_authentication(
                            "Libera.Chat did not offer SASL authentication"
                        )
                    else:
                        await self.write_immediately("CAP REQ :sasl")
            elif subcommand == "ACK" and "sasl" in params[-1].split():
                await self.write_immediately("AUTHENTICATE PLAIN")
            elif subcommand == "NAK":
                await self.fail_authentication("Libera.Chat rejected SASL negotiation")
        elif command == "AUTHENTICATE" and params and params[-1] == "+" and self.sasl_account:
            for chunk in sasl_plain_chunks(self.sasl_account, self.sasl_password):
                await self.write_immediately(f"AUTHENTICATE {chunk}")
        elif command == "903" and self.sasl_account:
            self.authenticated = True
            self.sasl_deadline = None
            await self.write_immediately("CAP END")
            self.emit("status", state="authenticating", message=f"Identified as {self.sasl_account}")
            if self.remember_login:
                await self.store_saved_login()
        elif command in {"902", "904", "905", "906", "907", "908"} and self.sasl_account:
            await self.fail_authentication(params[-1] if params else "NickServ authentication failed")
        elif command == "001":
            if self.sasl_account and not self.authenticated:
                await self.fail_authentication("NickServ authentication was not completed")
                return
            if params and params[0] != self.nickname:
                self.nickname = params[0]
                self.emit(
                    "nickname",
                    nickname=self.nickname,
                    message=f"Server confirmed nickname {self.nickname}",
                )
            await self.queue_line(f"JOIN {CHANNEL}")
        elif command == "433":
            if self.sasl_account:
                await self.stop_connection(
                    f"Nickname {self.requested_nickname} is connected elsewhere; "
                    "disconnect that IRC client and try again"
                )
            else:
                await self.select_guest_variant("Nickname was in use; selected a guest variant")
        elif command == "JOIN" and params:
            channel = params[-1]
            self.members[nick_key(source_nick)] = source_nick
            if source_nick == self.nickname and channel.lower() == CHANNEL:
                self.joined = True
                self.emit(
                    "connected",
                    channel=CHANNEL,
                    network="Libera.Chat",
                    nickname=self.nickname,
                    account=self.sasl_account if self.authenticated else "",
                )
                if self.authenticated:
                    await self.queue_line(f"PRIVMSG ChanServ :OP {CHANNEL}")
            else:
                if self.collecting_names:
                    self.pending_name_exclusions.discard(source_nick.lower())
                    if source_nick.lower() not in self.pending_name_keys:
                        self.pending_name_keys.add(source_nick.lower())
                        self.pending_names.append(source_nick)
                self.emit("join", nick=source_nick, channel=channel)
        elif command == "PRIVMSG" and len(params) >= 2:
            destination = params[0]
            if destination.lower() != CHANNEL and destination.lower() != self.nickname.lower():
                return
            target = CHANNEL if destination.lower() == CHANNEL else source_nick
            text = params[1]
            if text.startswith("\x01ACTION ") and text.endswith("\x01"):
                self.emit("action", nick=source_nick, target=target, text=text[8:-1], own=False)
            elif not text.startswith("\x01"):
                self.emit("message", nick=source_nick, target=target, text=text, own=False)
        elif command == "NOTICE" and params:
            text = params[-1]
            if (not self.sasl_account and source_nick.lower() == "nickserv"
                    and "nickname is registered" in text.lower()):
                await self.select_guest_variant(
                    "Nickname requires an account; selected a guest variant"
                )
            elif not text.startswith("\x01"):
                self.emit("notice", nick=source_nick, text=text)
        elif command == "NICK" and params:
            new_nick = params[-1]
            old_key = nick_key(source_nick)
            new_key = nick_key(new_nick)
            self.pending_bans.pop(old_key, None)
            was_operator = old_key in self.operators
            self.members.pop(old_key, None)
            self.members[new_key] = new_nick
            self.operators.discard(old_key)
            if was_operator:
                self.operators.add(new_key)
            if source_nick == self.nickname:
                self.nickname = new_nick
                self.emit("nickname", nickname=new_nick, message=f"You are now {new_nick}")
            else:
                old_key = source_nick.lower()
                if self.collecting_names:
                    self.pending_name_exclusions.add(old_key)
                    self.pending_name_exclusions.discard(new_nick.lower())
                    if old_key in self.pending_operators:
                        self.pending_operators.remove(old_key)
                        self.pending_operators.add(new_key)
                    if old_key in self.pending_name_keys:
                        self.pending_name_keys.remove(old_key)
                        self.pending_names = [name for name in self.pending_names
                                              if name.lower() != old_key]
                    if new_nick.lower() not in self.pending_name_keys:
                        self.pending_name_keys.add(new_nick.lower())
                        self.pending_names.append(new_nick)
                self.emit("nick", nick=source_nick, newNick=new_nick)
            if was_operator:
                self.emit("operator", nick=new_nick, operator=True)
        elif command == "353" and params:
            self.collecting_names = True
            for raw_name in params[-1].split():
                name = raw_name.lstrip("~&@%+")
                key = nick_key(name)
                if "@" in raw_name[:len(raw_name) - len(name)]:
                    self.pending_operators.add(key)
                if name and key not in self.pending_name_keys and key not in self.pending_name_exclusions:
                    self.pending_name_keys.add(key)
                    self.pending_names.append(name)
        elif command == "366":
            self.members = {nick_key(name): name for name in self.pending_names}
            self.operators = self.pending_operators & set(self.members)
            operator_names = [self.members[key] for key in self.operators]
            self.emit(
                "names",
                channel=CHANNEL,
                users=self.pending_names,
                operators=operator_names,
            )
            self.pending_names = []
            self.pending_name_keys = set()
            self.pending_name_exclusions = set()
            self.pending_operators = set()
            self.collecting_names = False
        elif command == "MODE" and len(params) >= 2 and params[0].lower() == CHANNEL:
            await self.handle_channel_modes(params[1], params[2:])
        elif command == "330" and len(params) >= 3:
            self.schedule_background(self.finish_ban(params[1], params[2]))
        elif command == "318" and len(params) >= 2:
            self.schedule_background(self.finish_ban(params[1], ""))
        elif command == "KICK" and len(params) >= 2 and params[0].lower() == CHANNEL:
            target = params[1]
            self.remove_member(target)
            own = nick_key(target) == nick_key(self.nickname)
            if own:
                self.joined = False
            self.emit(
                "kick",
                nick=target,
                by=source_nick,
                reason=params[2] if len(params) >= 3 else "",
                own=own,
            )
            if own:
                self.want_connection = False
                self.sasl_account = ""
                self.sasl_password = ""
                self.authenticated = False
                self.emit("disconnected", message=f"Kicked from {CHANNEL}")
                await self.write_immediately("QUIT :Kicked from channel")
        elif command == "PART" and params:
            key = nick_key(source_nick)
            self.remove_member(source_nick)
            if self.collecting_names:
                self.pending_name_exclusions.add(key)
                self.pending_operators.discard(key)
                if key in self.pending_name_keys:
                    self.pending_name_keys.remove(key)
                    self.pending_names = [name for name in self.pending_names if name.lower() != key]
            self.emit("part", nick=source_nick, channel=params[0])
        elif command == "QUIT":
            key = nick_key(source_nick)
            self.remove_member(source_nick)
            if self.collecting_names:
                self.pending_name_exclusions.add(key)
                self.pending_operators.discard(key)
                if key in self.pending_name_keys:
                    self.pending_name_keys.remove(key)
                    self.pending_names = [name for name in self.pending_names if name.lower() != key]
            self.emit("quit", nick=source_nick, message=params[-1] if params else "")
        elif command.isdigit() and command[0] in "45" and params:
            self.emit("error", message=params[-1])

    async def handle_channel_modes(self, modes: str, arguments: tuple[str, ...]) -> None:
        adding = True
        argument_index = 0
        for mode in modes:
            if mode == "+":
                adding = True
                continue
            if mode == "-":
                adding = False
                continue
            takes_argument = mode in "beIovqk" or (adding and mode in "fjl")
            argument = arguments[argument_index] if takes_argument and argument_index < len(arguments) else ""
            if takes_argument:
                argument_index += 1
            if mode != "o" or not argument:
                continue
            key = nick_key(argument)
            if adding:
                self.operators.add(key)
            else:
                self.operators.discard(key)
            self.emit("operator", nick=argument, operator=adding)

    async def finish_ban(self, nickname: str, account: str) -> None:
        pending = self.pending_bans.pop(nick_key(nickname), None)
        if pending is None:
            return
        target, reason = pending
        async with self.send_lock:
            await self.wait_for_send_slot()
            key = nick_key(target)
            if (not self.joined or nick_key(self.nickname) not in self.operators
                    or self.members.get(key) != target):
                self.emit(
                    "error",
                    message=f"Ban canceled because {target} or your operator status changed",
                )
                return
            mask = f"$a:{account}" if ACCOUNT_RE.fullmatch(account) else f"{target}!*@*"
            await self.write_batch_immediately([
                f"MODE {CHANNEL} +b {mask}",
                f"KICK {CHANNEL} {target} :{reason}",
            ])
            self.last_send_time = asyncio.get_running_loop().time()

    def remove_member(self, nickname: str) -> None:
        key = nick_key(nickname)
        self.members.pop(key, None)
        self.operators.discard(key)
        self.pending_bans.pop(key, None)

    async def fail_authentication(self, message: str) -> None:
        await self.stop_connection(f"NickServ authentication failed: {message}")

    async def stop_connection(self, message: str) -> None:
        self.want_connection = False
        self.sasl_account = ""
        self.sasl_password = ""
        self.authenticated = False
        self.sasl_deadline = None
        self.emit("error", message=message)
        self.emit("disconnected", message=message)
        await self.write_immediately("QUIT :Connection stopped")

    async def disconnect(self, _reason: str | None) -> None:
        self.joined = False
        tasks = list(self.background_tasks)
        self.background_tasks.clear()
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        writer, self.writer = self.writer, None
        self.reader = None
        self.sasl_deadline = None
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except (OSError, ssl.SSLError):
                pass


async def main() -> None:
    client = IrcClient()
    history = await asyncio.to_thread(client.load_history)
    client.emit("history", messages=history)
    await client.load_saved_login()
    await client.command_loop()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
