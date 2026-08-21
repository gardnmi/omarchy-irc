import asyncio
import json
import unittest

from irc_helper import (
    IrcClient,
    decode_client_command,
    encode_irc,
    parse_irc_line,
    validate_nickname,
)


class ParserTests(unittest.TestCase):
    def test_parses_prefix_and_unicode_trailing_text(self):
        message = parse_irc_line(":nick!user@host PRIVMSG #omachee :hello λ\r\n")
        self.assertEqual(message.prefix, "nick!user@host")
        self.assertEqual(message.command, "PRIVMSG")
        self.assertEqual(message.params, ("#omachee", "hello λ"))

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

    def test_json_events_support_unicode(self):
        encoded = json.dumps({"event": "message", "text": "hello λ"}, ensure_ascii=False)
        self.assertEqual(json.loads(encoded)["text"], "hello λ")


if __name__ == "__main__":
    unittest.main()
