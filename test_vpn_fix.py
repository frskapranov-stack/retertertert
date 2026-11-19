#!/usr/bin/env python3
"""Unit + fake-router tests for vpn_fix.py. No real Keenetic required."""

from __future__ import annotations

import hashlib
import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlparse

import vpn_fix


PROTECTED = vpn_fix.PROTECTED_HOSTS


class DomainTests(unittest.TestCase):
    def test_normalize_strips_urls_and_wildcards(self) -> None:
        self.assertEqual(vpn_fix.normalize_domain("https://Instagram.COM/reels"), "instagram.com")
        self.assertEqual(vpn_fix.normalize_domain("*.cursor.sh"), "cursor.sh")
        self.assertEqual(vpn_fix.normalize_domain("# comment"), "")
        self.assertEqual(vpn_fix.normalize_domain("fbcdn.net  # cdn"), "fbcdn.net")

    def test_short_sld_rejected(self) -> None:
        self.assertIsNotNone(vpn_fix.is_unsafe_domain("x.com"))
        self.assertIsNotNone(vpn_fix.is_unsafe_domain("fb.com"))
        self.assertIsNotNone(vpn_fix.is_unsafe_domain("ig.me"))
        self.assertIsNone(vpn_fix.is_unsafe_domain("instagram.com"))
        self.assertIsNone(vpn_fix.is_unsafe_domain("accounts.x.ai"))

    def test_lists_do_not_hijack_russian_sites(self) -> None:
        instagram = vpn_fix.load_domains(
            os.path.join(vpn_fix.script_dir(), "vpn", "instagram-domains.txt"),
            vpn_fix.FALLBACK_INSTAGRAM,
        )
        cursor = vpn_fix.load_domains(
            os.path.join(vpn_fix.script_dir(), "vpn", "cursor-domains.txt"),
            vpn_fix.FALLBACK_CURSOR,
        )
        self.assertIn("instagram.com", instagram)
        self.assertIn("facebook.com", instagram)
        self.assertIn("cursor.sh", cursor)
        self.assertNotIn("fb.com", instagram)
        self.assertNotIn("x.ai", cursor)
        for domain in instagram + cursor:
            for host in PROTECTED:
                self.assertFalse(
                    domain != host and domain in host,
                    f"{domain} would capture {host}",
                )

    def test_print_domains_exits_zero(self) -> None:
        self.assertEqual(vpn_fix.main(["--print-domains"]), 0)


class AuthTests(unittest.TestCase):
    def test_auth_key_matches_ndms_formula(self) -> None:
        login, realm, password, challenge = "admin", "Keenetic Giga", "secret", "ab" * 16
        digest = hashlib.md5(f"{login}:{realm}:{password}".encode()).hexdigest()
        expected = hashlib.sha256((challenge + digest).encode()).hexdigest()
        self.assertEqual(vpn_fix.auth_key(login, realm, password, challenge), expected)


class PickTests(unittest.TestCase):
    def test_prefers_existing_dns_route_iface_and_up_vpn(self) -> None:
        interfaces = {
            "PPPoE0": {
                "id": "PPPoE0",
                "type": "PPPoE",
                "connected": "yes",
                "global": True,
                "defaultgw": "yes",
            },
            "Wireguard0": {
                "id": "Wireguard0",
                "type": "Wireguard",
                "connected": "no",
                "description": "Amnezia",
            },
            "Wireguard1": {
                "id": "Wireguard1",
                "type": "Wireguard",
                "connected": "yes",
            },
        }
        wan = vpn_fix.pick_wan(interfaces)
        self.assertIsNotNone(wan)
        assert wan is not None
        self.assertEqual(wan["id"], "PPPoE0")
        vpn = vpn_fix.pick_vpn(interfaces, "Wireguard0")
        self.assertIsNotNone(vpn)
        assert vpn is not None
        self.assertEqual(vpn["id"], "Wireguard0")
        vpn_up = vpn_fix.pick_vpn(interfaces, None)
        assert vpn_up is not None
        self.assertEqual(vpn_up["id"], "Wireguard1")

    def test_walk_errors_ignores_message_status(self) -> None:
        payload = {
            "status": [{"status": "message", "message": "saving"}],
            "nested": {"status": [{"status": "error", "message": "boom"}]},
        }
        self.assertEqual(vpn_fix.walk_errors(payload), ["boom"])


class FakeState:
    def __init__(self) -> None:
        self.challenge = "c" * 32
        self.realm = "Keenetic Giga"
        self.login = "admin"
        self.password = "secret"
        self.sessions: set[str] = set()
        self.sid = "test-sid"
        self.saved = False
        self.rebooted = False
        self.hotspot_policy = "Policy0"
        self.interfaces: dict[str, dict[str, Any]] = {
            "PPPoE0": {
                "id": "PPPoE0",
                "type": "PPPoE",
                "connected": "yes",
                "state": "up",
                "link": "up",
                "global": True,
                "defaultgw": "yes",
                "description": "Internet",
            },
            "Wireguard0": {
                "id": "Wireguard0",
                "type": "Wireguard",
                "connected": "no",
                "state": "down",
                "link": "down",
                "description": "VPN",
            },
        }
        self.groups: dict[str, Any] = {}
        self.routes: list[dict[str, Any]] = []
        self.version = {"title": "5.1.8", "model": "Giga (KN-1010)"}


STATE = FakeState()


def _json_body(handler: BaseHTTPRequestHandler) -> Any:
    length = int(handler.headers.get("Content-Length") or 0)
    if length <= 0:
        return None
    raw = handler.rfile.read(length)
    return json.loads(raw.decode())


class FakeKeeneticHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003
        return

    def _sid(self) -> str | None:
        cookie = self.headers.get("Cookie") or ""
        for part in cookie.split(";"):
            part = part.strip()
            if part.startswith("sid="):
                return part.split("=", 1)[1]
        return None

    def _send(self, code: int, payload: Any = None, headers: dict[str, str] | None = None) -> None:
        body = b""
        extra = headers or {}
        if payload is not None:
            body = json.dumps(payload).encode()
            extra.setdefault("Content-Type", "application/json")
        self.send_response(code)
        for key, value in extra.items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, OSError):
                return

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/auth":
            self._send(
                401,
                {},
                {
                    "X-NDM-Realm": STATE.realm,
                    "X-NDM-Challenge": STATE.challenge,
                    "Set-Cookie": f"sid={STATE.sid}; Path=/; HttpOnly",
                    "WWW-Authenticate": (
                        f'x-ndw2-interactive realm="{STATE.realm}" '
                        f'challenge="{STATE.challenge}" session_cookie="sid"'
                    ),
                },
            )
            return
        if self._sid() not in STATE.sessions:
            self._send(401, {})
            return
        if path == "/rci/show/version":
            self._send(200, STATE.version)
            return
        if path == "/rci/show/interface":
            self._send(200, STATE.interfaces)
            return
        if path == "/rci/object-group/fqdn":
            self._send(200, STATE.groups)
            return
        if path == "/rci/dns-proxy/route":
            self._send(200, STATE.routes)
            return
        self._send(404, {})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        payload = _json_body(self)
        if path == "/auth":
            expected = vpn_fix.auth_key(STATE.login, STATE.realm, STATE.password, STATE.challenge)
            if not isinstance(payload, dict) or payload.get("password") != expected:
                self._send(401, {})
                return
            STATE.sessions.add(STATE.sid)
            self._send(200, {}, {"Set-Cookie": f"sid={STATE.sid}; Path=/"})
            return
        if self._sid() not in STATE.sessions:
            self._send(401, {})
            return
        if path != "/rci/":
            self._send(404, {})
            return
        self._handle_rci(payload)

    def _handle_rci(self, payload: Any) -> None:
        if isinstance(payload, list):
            for item in payload:
                self._handle_rci(item)
            self._send(200, {"status": [{"status": "ok"}]})
            return
        if not isinstance(payload, dict):
            self._send(200, {})
            return
        if "show" in payload:
            show = payload["show"]
            if "version" in show:
                self._send(200, {"show": {"version": STATE.version}})
                return
            if "interface" in show:
                self._send(200, {"show": {"interface": STATE.interfaces}})
                return
            self._send(200, {"show": show})
            return
        if "object-group" in payload:
            fqdn = payload["object-group"].get("fqdn") or {}
            for name, body in fqdn.items():
                current = STATE.groups.setdefault(name, {"description": "", "include": []})
                if body.get("description"):
                    current["description"] = body["description"]
                for item in body.get("include") or []:
                    addr = item.get("address") if isinstance(item, dict) else item
                    have = vpn_fix.include_addresses(current.get("include"))
                    if addr and addr not in have:
                        current.setdefault("include", []).append({"address": addr})
            self._send(200, {"status": [{"status": "ok"}]})
            return
        if "interface" in payload:
            for name, body in payload["interface"].items():
                up = body.get("up")
                self._set_iface(name, up is True)
            self._send(200, {"status": [{"status": "ok"}]})
            return
        if "system" in payload:
            system = payload["system"]
            if "reboot" in system:
                STATE.rebooted = True
            if "configuration" in system:
                STATE.saved = True
            self._send(200, {"status": [{"status": "message", "message": "saving"}]})
            return
        if "parse" in payload:
            command = str(payload["parse"]).strip()
            if command.startswith("interface ") and command.endswith(" up"):
                self._set_iface(command.split()[1], True)
            elif command.startswith("dns-proxy route object-group "):
                bits = command.split()
                group, iface = bits[3], bits[4]
                STATE.routes.append({"group": group, "interface": iface, "auto": True})
            elif command == "system configuration save":
                STATE.saved = True
            elif command == "system reboot":
                STATE.rebooted = True
            elif command == "no ip hotspot policy":
                STATE.hotspot_policy = "default"
            self._send(200, {"parse": {"status": [{"status": "message", "message": command}]}})
            return
        self._send(200, {})

    def _set_iface(self, name: str, up: bool) -> None:
        body = STATE.interfaces.setdefault(name, {"id": name, "type": "Wireguard"})
        flag = "yes" if up else "no"
        body["connected"] = flag
        body["state"] = "up" if up else "down"
        body["link"] = "up" if up else "down"


class FakeRouterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), FakeKeeneticHandler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self) -> None:
        global STATE
        STATE = FakeState()

    def test_wrong_password(self) -> None:
        code = vpn_fix.main(
            [
                "--host",
                f"127.0.0.1:{self.port}",
                "--user",
                "admin",
                "--password",
                "nope",
                "--diagnose",
                "--no-reboot",
            ]
        )
        self.assertEqual(code, 1)

    def test_diagnose_then_fix_brings_vpn_up_and_adds_routes(self) -> None:
        host = f"127.0.0.1:{self.port}"
        common = [
            "--host",
            host,
            "--user",
            "admin",
            "--password",
            "secret",
            "--no-reboot",
            "--wait",
            "0",
        ]
        self.assertEqual(vpn_fix.main(common + ["--diagnose"]), 0)
        self.assertFalse(STATE.interfaces["Wireguard0"]["connected"] == "yes")
        self.assertEqual(vpn_fix.main(common), 0)
        self.assertEqual(STATE.interfaces["Wireguard0"]["connected"], "yes")
        self.assertTrue(STATE.saved)
        self.assertFalse(STATE.rebooted)
        self.assertEqual(STATE.hotspot_policy, "default")
        groups = {name.lower() for name in STATE.groups}
        self.assertIn("instagram", groups)
        self.assertIn("cursor", groups)
        routed = {row["group"].lower() for row in STATE.routes}
        self.assertTrue({"instagram", "cursor"} <= routed)
        ig = next(iter(STATE.groups.values()))
        addrs = vpn_fix.include_addresses(ig["include"])
        self.assertIn("instagram.com", addrs)
        self.assertIn("facebook.com", addrs)

    def test_reboot_flag(self) -> None:
        code = vpn_fix.main(
            [
                "--host",
                f"127.0.0.1:{self.port}",
                "--user",
                "admin",
                "--password",
                "secret",
                "--reboot",
                "--wait",
                "0",
            ]
        )
        self.assertEqual(code, 0)
        self.assertTrue(STATE.rebooted)


if __name__ == "__main__":
    unittest.main()
