import asyncio
import base64
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from irc_helper import (
    HISTORY_LIMIT,
    IrcClient,
    decode_client_command,
    encode_irc,
    parse_irc_line,
    sasl_plain_chunks,
    validate_message_target,
    validate_nickname,
)


class ParserTests(unittest.TestCase):
    def test_parses_prefix_and_unicode_trailing_text(self):
        message = parse_irc_line(":nick!user@host PRIVMSG #omachee :hello\u2028λ\r\n")
        self.assertEqual(message.prefix, "nick!user@host")
        self.assertEqual(message.command, "PRIVMSG")
        self.assertEqual(message.params, ("#omachee", "hello\u2028λ"))

    def test_rejects_malformed_line(self):
        with self.assertRaises(ValueError):
            parse_irc_line(":prefix-only")

    def test_enforces_encoded_irc_limit(self):
        self.assertEqual(encode_irc("PING :ok"), b"PING :ok\r\n")
        with self.assertRaises(ValueError):
            encode_irc("PRIVMSG #omachee :" + "λ" * 300)

    def test_rejects_line_injection(self):
        with self.assertRaises(ValueError):
            encode_irc("PRIVMSG #omachee :hello\r\nQUIT")


class HistoryTests(unittest.TestCase):
    def test_history_is_bounded_atomic_and_private(self):
        with tempfile.TemporaryDirectory() as directory:
            client = IrcClient()
            client.history_path = Path(directory) / "omarchy-irc/history.json"

            for index in range(HISTORY_LIMIT + 5):
                client.store_history({
                    "kind": "message",
                    "nick": "gardnmi",
                    "text": f"message {index}",
                    "own": True,
                })

            messages = client.load_history()
            self.assertEqual(len(messages), HISTORY_LIMIT)
            self.assertEqual(messages[0]["text"], "message 5")
            self.assertEqual(messages[-1]["text"], f"message {HISTORY_LIMIT + 4}")
            self.assertEqual(os.stat(client.history_path).st_mode & 0o777, 0o600)
            self.assertEqual(list(client.history_path.parent.glob(".history-*.tmp")), [])

    def test_history_rejects_invalid_events_and_corrupt_files(self):
        with tempfile.TemporaryDirectory() as directory:
            client = IrcClient()
            client.history_path = Path(directory) / "history.json"

            with self.assertRaisesRegex(ValueError, "Invalid channel history"):
                client.store_history({
                    "kind": "notice",
                    "nick": "server",
                    "text": "not persisted",
                    "own": False,
                })

            client.history_path.write_text("not json", encoding="utf-8")
            self.assertEqual(client.load_history(), [])

    def test_clear_history_removes_persisted_messages(self):
        with tempfile.TemporaryDirectory() as directory:
            client = IrcClient()
            client.history_path = Path(directory) / "history.json"
            client.store_history({
                "kind": "action",
                "nick": "someone",
                "text": "waves",
                "own": False,
            })

            client.clear_history()

            self.assertFalse(client.history_path.exists())
            self.assertEqual(client.load_history(), [])


class IpcTests(unittest.TestCase):
    def test_decodes_command(self):
        self.assertEqual(
            decode_client_command('{"command":"send","text":"hello"}\n'),
            {"command": "send", "text": "hello"},
        )

    def test_rejects_malformed_json_and_shape(self):
        for value in ("{", "[]", '{"text":"missing"}'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                decode_client_command(value)

    def test_validates_nickname(self):
        self.assertEqual(validate_nickname("OmarchyUser42"), "OmarchyUser42")
        for nickname in ("", "42startsWrong", "has space", "x" * 17):
            with self.subTest(nickname=nickname), self.assertRaises(ValueError):
                validate_nickname(nickname)

    def test_validates_message_target(self):
        self.assertEqual(validate_message_target("#omachee"), "#omachee")
        self.assertEqual(validate_message_target("someone"), "someone")
        with self.assertRaises(ValueError):
            validate_message_target("#other")

    def test_direct_message_command_targets_selected_user(self):
        async def exercise():
            client = IrcClient()
            client.joined = True
            client.nickname = "Me"
            output = []
            client.emit = lambda event, **fields: output.append({"event": event, **fields})
            await client.handle_command({"command": "send", "target": "someone", "text": "hello"})
            self.assertEqual(client.outgoing.get_nowait(), "PRIVMSG someone :hello")
            self.assertEqual(output[0]["target"], "someone")
            self.assertTrue(output[0]["own"])

        asyncio.run(exercise())

    def test_load_saved_login_connects_without_exposing_password(self):
        async def exercise():
            client = IrcClient()
            client.keyring_command = AsyncMock(return_value=json.dumps({
                "account": "gardnmi",
                "password": "secret",
            }).encode())
            client.handle_command = AsyncMock()
            output = []
            client.emit = lambda event, **fields: output.append({"event": event, **fields})

            await client.load_saved_login()

            client.handle_command.assert_awaited_once_with({
                "command": "connect",
                "nickname": "gardnmi",
                "account": "gardnmi",
                "password": "secret",
                "remember": True,
            })
            self.assertEqual(output, [{
                "event": "saved_login",
                "saved": True,
                "account": "gardnmi",
            }])
            self.assertNotIn("password", output[0])

        asyncio.run(exercise())

    def test_store_saved_login_passes_json_through_stdin(self):
        async def exercise():
            client = IrcClient()
            client.sasl_account = "gardnmi"
            client.sasl_password = "secret"
            client.keyring_command = AsyncMock(return_value=b"")
            output = []
            client.emit = lambda event, **fields: output.append({"event": event, **fields})

            await client.store_saved_login()

            action, secret = client.keyring_command.await_args.args
            self.assertEqual(action, "store")
            self.assertEqual(json.loads(secret), {
                "account": "gardnmi",
                "password": "secret",
            })
            self.assertEqual(output[-1]["event"], "saved_login")

        asyncio.run(exercise())

    def test_keyring_store_keeps_secret_out_of_process_arguments(self):
        async def exercise():
            client = IrcClient()
            process = AsyncMock()
            process.communicate.return_value = (b"", b"")
            process.returncode = 0
            create_process = AsyncMock(return_value=process)

            with patch("irc_helper.asyncio.create_subprocess_exec", create_process):
                await client.keyring_command("store", b"sensitive credential")

            arguments = create_process.await_args.args
            self.assertNotIn("sensitive credential", " ".join(arguments))
            process.communicate.assert_awaited_once_with(b"sensitive credential")

        asyncio.run(exercise())

    def test_clear_saved_login_updates_panel_state(self):
        async def exercise():
            client = IrcClient()
            client.remember_login = True
            client.keyring_command = AsyncMock(return_value=b"")
            output = []
            client.emit = lambda event, **fields: output.append({"event": event, **fields})

            await client.clear_saved_login()

            client.keyring_command.assert_awaited_once_with("clear")
            self.assertFalse(client.remember_login)
            self.assertEqual(output, [{
                "event": "saved_login",
                "saved": False,
                "account": "",
            }])

        asyncio.run(exercise())

    def test_action_command_encodes_ctcp_internally(self):
        async def exercise():
            client = IrcClient()
            client.joined = True
            client.nickname = "Me"
            output = []
            client.emit = lambda event, **fields: output.append({"event": event, **fields})
            await client.handle_command({"command": "action", "target": "#omachee", "text": "waves"})
            self.assertEqual(client.outgoing.get_nowait(), "PRIVMSG #omachee :\x01ACTION waves\x01")
            self.assertEqual(output[0]["event"], "action")
            self.assertTrue(output[0]["own"])

        asyncio.run(exercise())

    def test_incoming_direct_message_uses_sender_as_target(self):
        async def exercise():
            client = IrcClient()
            client.nickname = "Me"
            output = []
            client.emit = lambda event, **fields: output.append({"event": event, **fields})
            await client.handle_irc(parse_irc_line(":someone!u@h PRIVMSG Me :hello"))
            self.assertEqual(output[0]["event"], "message")
            self.assertEqual(output[0]["target"], "someone")
            self.assertFalse(output[0]["own"])

        asyncio.run(exercise())

    def test_names_reply_removes_membership_prefixes(self):
        async def exercise():
            client = IrcClient()
            output = []
            client.emit = lambda event, **fields: output.append({"event": event, **fields})
            await client.handle_irc(parse_irc_line(":server 353 Me = #omachee :@alice +bob Me"))
            await client.handle_irc(parse_irc_line(":server 353 Me = #omachee :alice carol"))
            await client.handle_irc(parse_irc_line(":bob!u@h PART #omachee :bye"))
            await client.handle_irc(parse_irc_line(":alice!u@h NICK Alicia"))
            await client.handle_irc(parse_irc_line(":server 366 Me #omachee :End of NAMES"))
            self.assertEqual(output[-1]["users"], ["Me", "carol", "Alicia"])
            self.assertEqual(output[-1]["operators"], ["Alicia"])
            self.assertIn("alicia", client.operators)

        asyncio.run(exercise())

    def test_operator_status_controls_kick_command(self):
        async def exercise():
            client = IrcClient()
            client.joined = True
            client.nickname = "gardnmi"
            client.members = {"gardnmi": "gardnmi", "someone": "someone"}
            client.emit = lambda _event, **_fields: None
            batches = []

            async def write_batch(lines):
                batches.append(lines)

            client.write_batch_immediately = write_batch
            with self.assertRaisesRegex(ValueError, "operator status"):
                await client.handle_command({"command": "kick", "nickname": "someone"})

            await client.handle_irc(parse_irc_line(":ChanServ MODE #omachee +o gardnmi"))
            await client.handle_command({
                "command": "kick",
                "nickname": "someone",
                "reason": "Please cool down",
            })
            self.assertEqual(
                batches,
                [["KICK #omachee someone :Please cool down"]],
            )

        asyncio.run(exercise())

    def test_authenticated_user_can_request_and_drop_operator(self):
        async def exercise():
            client = IrcClient()
            client.joined = True
            client.authenticated = True
            client.nickname = "gardnmi"
            await client.handle_command({"command": "request_operator"})
            self.assertEqual(
                client.outgoing.get_nowait(),
                "PRIVMSG ChanServ :OP #omachee",
            )

            client.operators.add("gardnmi")
            await client.handle_command({"command": "drop_operator"})
            self.assertEqual(client.outgoing.get_nowait(), "MODE #omachee -o gardnmi")

        asyncio.run(exercise())

    def test_authenticated_join_automatically_requests_operator(self):
        async def exercise():
            client = IrcClient()
            client.nickname = "gardnmi"
            client.authenticated = True
            client.sasl_account = "gardnmi"
            client.emit = lambda _event, **_fields: None

            await client.handle_irc(parse_irc_line(":gardnmi!user@host JOIN #omachee"))

            self.assertTrue(client.joined)
            self.assertEqual(
                client.outgoing.get_nowait(),
                "PRIVMSG ChanServ :OP #omachee",
            )

        asyncio.run(exercise())

    def test_ban_prefers_account_and_falls_back_to_nickname(self):
        async def exercise():
            client = IrcClient()
            client.joined = True
            client.nickname = "gardnmi"
            client.operators.add("gardnmi")
            client.members = {
                "gardnmi": "gardnmi",
                "identified": "Identified",
                "guest": "Guest",
            }
            writes = []

            async def write_batch(lines):
                writes.extend(lines)

            client.write_batch_immediately = write_batch

            await client.handle_command({"command": "ban", "nickname": "Identified"})
            self.assertEqual(client.outgoing.get_nowait(), "WHOIS Identified")
            await client.handle_irc(parse_irc_line(
                ":server 330 gardnmi Identified accountname :is logged in as"
            ))
            await asyncio.gather(*list(client.background_tasks))
            self.assertEqual(
                writes,
                [
                    "MODE #omachee +b $a:accountname",
                    "KICK #omachee Identified :Banned by a channel operator",
                ],
            )

            await client.handle_command({"command": "ban", "nickname": "Guest"})
            self.assertEqual(client.outgoing.get_nowait(), "WHOIS Guest")
            client.last_send_time = 0.0
            await client.handle_irc(parse_irc_line(":server 318 gardnmi Guest :End of WHOIS"))
            await asyncio.gather(*list(client.background_tasks))
            self.assertEqual(
                writes[-2:],
                [
                    "MODE #omachee +b Guest!*@*",
                    "KICK #omachee Guest :Banned by a channel operator",
                ],
            )

        asyncio.run(exercise())

    def test_pending_ban_is_canceled_after_deop_or_nick_change(self):
        async def exercise():
            client = IrcClient()
            client.joined = True
            client.nickname = "gardnmi"
            client.operators.add("gardnmi")
            client.members = {"gardnmi": "gardnmi", "target": "Target"}
            output = []
            writes = []
            client.emit = lambda event, **fields: output.append({"event": event, **fields})

            async def write_batch(lines):
                writes.extend(lines)

            client.write_batch_immediately = write_batch
            await client.handle_command({"command": "ban", "nickname": "Target"})
            client.outgoing.get_nowait()
            await client.handle_irc(parse_irc_line(":ChanServ MODE #omachee -o gardnmi"))
            await client.handle_irc(parse_irc_line(
                ":server 330 gardnmi Target accountname :is logged in as"
            ))
            await asyncio.gather(*list(client.background_tasks))
            self.assertEqual(writes, [])
            self.assertIn("Ban canceled", output[-1]["message"])

            client.operators.add("gardnmi")
            await client.handle_command({"command": "ban", "nickname": "Target"})
            client.outgoing.get_nowait()
            await client.handle_irc(parse_irc_line(":Target!user@host NICK Renamed"))
            await client.handle_irc(parse_irc_line(
                ":server 330 gardnmi Target accountname :is logged in as"
            ))
            await asyncio.gather(*list(client.background_tasks))
            self.assertEqual(writes, [])

        asyncio.run(exercise())

    def test_collision_selects_variant_without_network(self):
        async def exercise():
            client = IrcClient()
            client.nickname = "OmarchyUser"
            client.requested_nickname = "OmarchyUser"
            output = []
            writes = []
            client.emit = lambda event, **fields: output.append({"event": event, **fields})

            async def write(line):
                writes.append(line)

            client.write_immediately = write
            await client.handle_irc(parse_irc_line(":server 433 * OmarchyUser :in use"))
            self.assertRegex(client.nickname, r"^OmarchyUser_\d{2}$")
            self.assertEqual(writes, [f"NICK {client.nickname}"])
            self.assertEqual(output[0]["event"], "nickname")

        asyncio.run(exercise())

    def test_registered_nickname_selects_guest_variant(self):
        async def exercise():
            client = IrcClient()
            client.nickname = "timothy"
            client.requested_nickname = "timothy"
            output = []
            writes = []
            client.emit = lambda event, **fields: output.append({"event": event, **fields})

            async def write(line):
                writes.append(line)

            client.write_immediately = write
            await client.handle_irc(parse_irc_line(
                ":NickServ!service@libera NOTICE timothy :This nickname is registered. Please choose a different nickname"
            ))
            self.assertRegex(client.nickname, r"^timothy_\d{2}$")
            self.assertEqual(writes, [f"NICK {client.nickname}"])
            self.assertEqual(output[0]["event"], "nickname")

        asyncio.run(exercise())

    def test_sasl_plain_authenticates_before_join(self):
        async def exercise():
            client = IrcClient()
            client.nickname = "gardnmi"
            client.requested_nickname = "gardnmi"
            client.sasl_account = "gardnmi"
            client.sasl_password = "secret"
            writes = []
            output = []
            client.emit = lambda event, **fields: output.append({"event": event, **fields})

            async def write(line):
                writes.append(line)

            client.write_immediately = write
            await client.handle_irc(parse_irc_line(":server CAP gardnmi LS * :account-notify"))
            await client.handle_irc(parse_irc_line(":server CAP gardnmi LS :sasl=PLAIN"))
            await client.handle_irc(parse_irc_line(":server CAP gardnmi ACK :sasl"))
            await client.handle_irc(parse_irc_line("AUTHENTICATE +"))
            await client.handle_irc(parse_irc_line(":server 903 gardnmi :SASL authentication successful"))
            await client.handle_irc(parse_irc_line(":server 001 gardnmi :Welcome"))

            self.assertEqual(writes[:2], ["CAP REQ :sasl", "AUTHENTICATE PLAIN"])
            encoded = writes[2].split(" ", 1)[1]
            self.assertEqual(base64.b64decode(encoded), b"\0gardnmi\0secret")
            self.assertEqual(writes[3], "CAP END")
            self.assertEqual(client.outgoing.get_nowait(), "JOIN #omachee")
            self.assertTrue(client.authenticated)
            self.assertNotIn("secret", json.dumps(output))

        asyncio.run(exercise())

    def test_remembered_login_is_saved_only_after_sasl_success(self):
        async def exercise():
            client = IrcClient()
            client.sasl_account = "gardnmi"
            client.sasl_password = "secret"
            client.remember_login = True
            client.write_immediately = AsyncMock()
            client.store_saved_login = AsyncMock()
            client.emit = lambda _event, **_fields: None

            self.assertEqual(client.store_saved_login.await_count, 0)
            await client.handle_irc(parse_irc_line(
                ":server 903 gardnmi :SASL authentication successful"
            ))

            client.store_saved_login.assert_awaited_once_with()

        asyncio.run(exercise())

    def test_sasl_failure_clears_credentials_and_stops(self):
        async def exercise():
            for numeric in ("902", "904"):
                client = IrcClient()
                client.want_connection = True
                client.sasl_account = "gardnmi"
                client.sasl_password = "secret"
                writes = []
                output = []
                client.emit = lambda event, **fields: output.append({"event": event, **fields})

                async def write(line):
                    writes.append(line)

                client.write_immediately = write
                await client.handle_irc(parse_irc_line(
                    f":server {numeric} gardnmi :Invalid credentials"
                ))

                with self.subTest(numeric=numeric):
                    self.assertFalse(client.want_connection)
                    self.assertEqual(client.sasl_account, "")
                    self.assertEqual(client.sasl_password, "")
                    self.assertEqual(writes, ["QUIT :Connection stopped"])
                    self.assertEqual(output[-1]["event"], "disconnected")
                    self.assertNotIn("secret", json.dumps(output))

        asyncio.run(exercise())

    def test_sasl_nickname_collision_does_not_join_with_variant(self):
        async def exercise():
            client = IrcClient()
            client.want_connection = True
            client.nickname = "gardnmi"
            client.requested_nickname = "gardnmi"
            client.sasl_account = "gardnmi"
            client.sasl_password = "secret"
            writes = []
            output = []
            client.emit = lambda event, **fields: output.append({"event": event, **fields})

            async def write(line):
                writes.append(line)

            client.write_immediately = write
            await client.handle_irc(parse_irc_line(":server 433 * gardnmi :Nickname is already in use"))

            self.assertFalse(client.want_connection)
            self.assertEqual(client.nickname, "gardnmi")
            self.assertEqual(writes, ["QUIT :Connection stopped"])
            self.assertIn("connected elsewhere", output[-1]["message"])

        asyncio.run(exercise())

    def test_sasl_payload_uses_irc_chunk_limit(self):
        chunks = sasl_plain_chunks("account", "x" * 600)
        self.assertTrue(all(chunk == "+" or len(chunk) <= 400 for chunk in chunks))

    def test_json_events_support_unicode(self):
        text = "hello λ 😮‍💨"
        encoded = json.dumps({"event": "message", "text": text}, ensure_ascii=False)
        self.assertEqual(json.loads(encoded)["text"], text)


if __name__ == "__main__":
    unittest.main()
