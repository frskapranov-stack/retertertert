#!/usr/bin/env python3
"""Repair Keenetic split-tunnel: bring VPN up, restore WAN, route Instagram + Cursor.

Run on a computer that is on the home Wi-Fi (192.168.3.1). Cloud agents cannot
reach that address. Password: KEENETIC_PASSWORD or an interactive prompt.
Never stored in this repository.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import http.cookiejar
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from typing import Any

DEFAULT_HOST = "192.168.3.1"
DEFAULT_USER = "admin"
VPN_TYPES = {
    "wireguard",
    "openvpn",
    "sstp",
    "pptp",
    "l2tp",
    "ipsec",
    "openconnect",
    "ctun",
    "wireguardpeer",
    "amneziawg",
}
VPN_NAME_HINT = (
    "wireguard",
    "amnezia",
    "openvpn",
    "sstp",
    "pptp",
    "l2tp",
    "ipsec",
    "outline",
    "vpn",
)
# Names that must never be captured by a too-short FQDN rule.
PROTECTED_HOSTS = (
    "yandex.com",
    "ya.ru",
    "google.com",
    "googleapis.com",
    "gstatic.com",
    "youtube.com",
    "vk.com",
    "mail.ru",
    "ok.ru",
    "avito.ru",
    "gosuslugi.ru",
    "sberbank.ru",
    "tinkoff.ru",
    "ozon.ru",
    "wildberries.ru",
    "dzen.ru",
)
FALLBACK_INSTAGRAM = (
    "instagram.com",
    "cdninstagram.com",
    "instagram.net",
    "igsonar.com",
    "igcdn.com",
    "instagr.am",
    "facebook.com",
    "facebook.net",
    "fbcdn.net",
    "fbsbx.com",
    "cdnfacebook.com",
    "messenger.com",
    "tfbnw.net",
)
FALLBACK_CURSOR = (
    "cursor.com",
    "cursor.sh",
    "cursor-cdn.com",
    "cursorapi.com",
    "cursorvm.com",
    "accounts.spacex.ai",
    "accounts.x.ai",
    "anysphere-binaries.s3.us-east-1.amazonaws.com",
    "agent-stores.s3.us-east-1.amazonaws.com",
    "agent-stores.s3.amazonaws.com",
    "cursor.blob.core.windows.net",
    "authenticator.cursor.sh",
    "marketplace.cursorapi.com",
    "downloads.cursor.com",
    "us1.cursor-cdn.com",
    "eu1.cursor-cdn.com",
)


class RouterError(Exception):
    """User-facing failure talking to the Keenetic."""


def md5_hex(text: str) -> str:
    return hashlib.md5(text.encode()).hexdigest()


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def auth_key(login: str, realm: str, password: str, challenge: str) -> str:
    digest = md5_hex(f"{login}:{realm}:{password}")
    return sha256_hex(challenge + digest)


def header(headers: Any, name: str) -> str | None:
    if headers is None:
        return None
    getter = getattr(headers, "get", None)
    if callable(getter):
        value = getter(name) or getter(name.lower())
        if value:
            return str(value)
    try:
        items = headers.items()
    except Exception:
        return None
    want = name.lower()
    for key, value in items:
        if str(key).lower() == want:
            return str(value)
    return None


def normalize_domain(raw: str) -> str:
    text = raw.strip().lower()
    if not text or text.startswith("#"):
        return ""
    text = text.split("#", 1)[0].strip()
    text = text.replace("https://", "").replace("http://", "")
    text = text.split("/", 1)[0]
    text = text.rstrip(".")
    if text.startswith("*."):
        text = text[2:]
    return text


def sld_label(domain: str) -> str:
    parts = [p for p in domain.split(".") if p]
    if len(parts) < 2:
        return domain
    return parts[-2]


def is_unsafe_domain(domain: str) -> str | None:
    """Return a reason if Keenetic substring matching would be too broad."""
    if not domain or "." not in domain:
        return "not a hostname"
    if any(ch.isspace() or ch in "?*" for ch in domain):
        return "wildcards are not allowed"
    label = sld_label(domain)
    if len(label) <= 2 and domain.count(".") == 1:
        return f"short name {domain!r} is a substring match (x.com captures yandex.com)"
    for host in PROTECTED_HOSTS:
        if domain != host and domain in host:
            return f"{domain!r} would also match {host}"
    return None


def load_domains(path: str, fallback: tuple[str, ...]) -> list[str]:
    rows: list[str] = []
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as handle:
            rows = [normalize_domain(line) for line in handle]
    else:
        rows = [normalize_domain(item) for item in fallback]
    out: list[str] = []
    seen: set[str] = set()
    for domain in rows:
        if not domain or domain in seen:
            continue
        reason = is_unsafe_domain(domain)
        if reason:
            print(f"пропуск {domain}: {reason}", file=sys.stderr)
            continue
        seen.add(domain)
        out.append(domain)
    return out


def unwrap_show(payload: Any, *parts: str) -> Any:
    node = payload
    if isinstance(node, dict) and "show" in node and parts:
        node = node["show"]
    for part in parts:
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            break
    return node


def as_map(node: Any) -> dict[str, Any]:
    if node is None:
        return {}
    if isinstance(node, dict):
        return {str(key): value for key, value in node.items() if not str(key).startswith("_")}
    if isinstance(node, list):
        merged: dict[str, Any] = {}
        for item in node:
            merged.update(as_map(item))
        return merged
    return {}


def walk_errors(node: Any, sink: list[str] | None = None) -> list[str]:
    sink = sink if sink is not None else []
    if node is None:
        return sink
    if isinstance(node, list):
        for item in node:
            walk_errors(item, sink)
        return sink
    if not isinstance(node, dict):
        return sink
    status = node.get("status")
    if isinstance(status, str) and status.lower() == "error":
        sink.append(str(node.get("message") or "RCI error"))
    else:
        walk_errors(status, sink)
    for key, value in node.items():
        if key == "status":
            continue
        walk_errors(value, sink)
    return sink


def prop(node: Any, *names: str) -> Any:
    if not isinstance(node, dict):
        return None
    for name in names:
        if name in node:
            return node[name]
        for key, value in node.items():
            if str(key).lower() == name.lower():
                return value
    return None


def include_addresses(include: Any) -> list[str]:
    out: list[str] = []
    if include is None:
        return out
    if isinstance(include, str):
        domain = normalize_domain(include)
        return [domain] if domain else out
    if isinstance(include, dict):
        include = [include]
    for item in include:
        if isinstance(item, str):
            domain = normalize_domain(item)
        else:
            domain = normalize_domain(str(prop(item, "address", "Address") or ""))
        if domain:
            out.append(domain)
    return out


def is_up(body: dict[str, Any]) -> bool:
    connected = str(prop(body, "connected") or "").lower()
    state = str(prop(body, "state") or "").lower()
    link = str(prop(body, "link") or "").lower()
    return connected in {"yes", "true"} or state == "up" or link == "up"


def is_vpn(name: str, body: dict[str, Any]) -> bool:
    typ = str(prop(body, "type") or "")
    if typ.lower() in VPN_TYPES:
        return True
    blob = " ".join(
        [
            name,
            str(prop(body, "id") or ""),
            str(prop(body, "description") or ""),
            typ,
        ]
    ).lower()
    return any(hint in blob for hint in VPN_NAME_HINT)


def pick_vpn(
    interfaces: dict[str, dict[str, Any]], preferred: str | None
) -> dict[str, Any] | None:
    found: list[dict[str, Any]] = []
    for name, body in interfaces.items():
        if not isinstance(body, dict):
            continue
        if not is_vpn(name, body):
            continue
        ident = str(prop(body, "id") or name)
        found.append(
            {
                "id": ident,
                "name": name,
                "description": str(prop(body, "description") or ""),
                "type": str(prop(body, "type") or ""),
                "up": is_up(body),
                "body": body,
            }
        )
    if preferred:
        for item in found:
            if item["id"].lower() == preferred.lower() or item["name"].lower() == preferred.lower():
                return item
        return {
            "id": preferred,
            "name": preferred,
            "description": "",
            "type": "",
            "up": True,
            "body": {},
        }
    return next((item for item in found if item["up"]), None) or (found[0] if found else None)


def pick_wan(interfaces: dict[str, dict[str, Any]]) -> dict[str, Any] | None:
    candidates: list[dict[str, Any]] = []
    for name, body in interfaces.items():
        if not isinstance(body, dict) or is_vpn(name, body):
            continue
        ident = str(prop(body, "id") or name)
        if ident.lower().startswith(("bridge", "wifi", "switch", "guest")):
            continue
        global_flag = prop(body, "global")
        connected = is_up(body)
        defaultgw = str(prop(body, "defaultgw") or "").lower() in {"yes", "true"}
        score = int(bool(global_flag)) * 2 + int(connected) + int(defaultgw) * 3
        if score <= 0:
            continue
        candidates.append(
            {
                "id": ident,
                "name": name,
                "description": str(prop(body, "description") or ""),
                "type": str(prop(body, "type") or ""),
                "up": connected,
                "score": score,
            }
        )
    if not candidates:
        return None
    candidates.sort(key=lambda item: item["score"], reverse=True)
    return candidates[0]


class Keenetic:
    def __init__(self, host: str, user: str, password: str, timeout: float = 12.0):
        self.host = host
        self.user = user
        self.password = password
        self.timeout = timeout
        self.base = ""
        self.jar = http.cookiejar.CookieJar()
        ctx = ssl._create_unverified_context()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar),
            urllib.request.HTTPSHandler(context=ctx),
        )

    def request(self, method: str, path: str, payload: Any | None = None) -> tuple[int, Any, bytes]:
        data = None
        headers = {"Accept": "application/json", "User-Agent": "vpn-fix"}
        if payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json; charset=utf-8"
        url = self.base + path
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=self.timeout) as resp:
                self._absorb_cookies(resp.headers, req)
                body = resp.read()
                return resp.status, resp.headers, body
        except urllib.error.HTTPError as exc:
            self._absorb_cookies(exc.headers, req)
            return exc.code, exc.headers, exc.read()
        except urllib.error.URLError as exc:
            raise RouterError(
                f"Роутер {self.host} недоступен ({exc.reason}). "
                "Запустите скрипт с компьютера в домашней Wi‑Fi, не из облака."
            ) from None
        except TimeoutError as exc:
            raise RouterError(f"Таймаут {self.host}. Проверьте, что вы в домашней сети.") from exc

    def _absorb_cookies(self, headers: Any, req: urllib.request.Request) -> None:
        if headers is None:
            return

        class _Resp:
            def info(self_inner):
                return headers

        try:
            self.jar.extract_cookies(_Resp(), req)
        except Exception:
            raw = header(headers, "Set-Cookie")
            if not raw or "=" not in raw:
                return
            name, _, rest = raw.split(";", 1)[0].partition("=")
            cookie = http.cookiejar.Cookie(
                0,
                name.strip(),
                rest.strip(),
                None,
                False,
                self.host.split(":")[0],
                False,
                False,
                "/",
                True,
                False,
                None,
                True,
                None,
                None,
                {},
            )
            self.jar.set_cookie(cookie)

    def connect(self) -> None:
        last: Exception | None = None
        for scheme in ("http", "https"):
            self.base = f"{scheme}://{self.host}".rstrip("/")
            self.jar.clear()
            try:
                code, headers, _ = self.request("GET", "/auth")
            except RouterError as exc:
                last = exc
                continue
            realm = header(headers, "X-NDM-Realm")
            challenge = header(headers, "X-NDM-Challenge")
            if not realm or not challenge:
                www = header(headers, "WWW-Authenticate") or ""
                if 'realm="' in www:
                    realm = www.split('realm="', 1)[1].split('"', 1)[0]
                if 'challenge="' in www:
                    challenge = www.split('challenge="', 1)[1].split('"', 1)[0]
            if code == 200 and not challenge:
                return
            if not realm or not challenge:
                last = RouterError(
                    "Это не Keenetic RCI (нет X-NDM-Challenge). "
                    "Откройте http://192.168.3.1 в браузере и настройте маршруты DNS вручную."
                )
                continue
            key = auth_key(self.user, realm, self.password, challenge)
            code, _, body = self.request(
                "POST", "/auth", {"login": self.user, "password": key}
            )
            if code != 200:
                raise RouterError("Неверный логин или пароль администратора роутера.")
            data = json.loads(body.decode() or "{}") if body else {}
            if isinstance(data, dict) and data.get("ndsso"):
                raise RouterError("Роутер требует вход через Keenetic ID (NDSSO). Создайте локального admin.")
            return
        if last:
            raise last
        raise RouterError("Не удалось подключиться к роутеру.")

    def rci(self, payload: Any) -> Any:
        code, _, body = self.request("POST", "/rci/", payload)
        if code == 401:
            self.connect()
            code, _, body = self.request("POST", "/rci/", payload)
        if code != 200:
            snippet = body.decode("utf-8", "replace")[:240]
            raise RouterError(f"RCI HTTP {code}: {snippet}")
        if not body.strip():
            return None
        parsed = json.loads(body.decode("utf-8", "replace"))
        errors = walk_errors(parsed)
        if errors:
            raise RouterError("; ".join(dict.fromkeys(errors)))
        return parsed

    def get(self, path: str) -> Any:
        code, _, body = self.request("GET", "/rci/" + path.lstrip("/"))
        if code == 401:
            self.connect()
            code, _, body = self.request("GET", "/rci/" + path.lstrip("/"))
        if code == 404:
            return None
        if code != 200:
            return None
        if not body.strip():
            return None
        try:
            return json.loads(body.decode("utf-8", "replace"))
        except json.JSONDecodeError:
            return None

    def show(self, *parts: str) -> Any:
        path = "/".join(parts)
        got = self.get("show/" + path)
        if got is not None:
            return unwrap_show(got, *parts)
        node: dict[str, Any] = {}
        cursor = node
        for part in parts[:-1]:
            nxt: dict[str, Any] = {}
            cursor[part] = nxt
            cursor = nxt
        cursor[parts[-1]] = {}
        return unwrap_show(self.rci({"show": node}), *parts)

    def parse(self, command: str) -> Any:
        return self.rci({"parse": command})

    def save(self) -> None:
        try:
            self.parse("system configuration save")
        except RouterError:
            self.rci({"system": {"configuration": {"save": {}}}})

    def reboot(self) -> None:
        try:
            self.parse("system reboot")
        except RouterError:
            self.rci({"system": {"reboot": {}}})

    def set_up(self, iface: str, up: bool) -> None:
        try:
            self.parse(f"interface {iface} {'up' if up else 'down'}")
            return
        except RouterError:
            pass
        self.rci({"interface": {iface: {"up": True if up else {"no": True}}}})


def script_dir() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def read_password(explicit: str | None) -> str:
    if explicit:
        return explicit
    env = os.environ.get("KEENETIC_PASSWORD")
    if env:
        return env
    if sys.stdin.isatty():
        value = getpass.getpass("Пароль администратора роутера (admin @ 192.168.3.1): ")
        if value:
            return value
    raise RouterError(
        "Пароль не задан. Запустите из Терминала или: export KEENETIC_PASSWORD='…'"
    )


def preferred_route_iface(routes: list[dict[str, Any]]) -> str | None:
    for route in routes:
        iface = prop(route, "interface", "Interface")
        if iface:
            return str(iface)
    return None


def normalize_routes(raw: Any) -> list[dict[str, Any]]:
    if raw is None:
        return []
    if isinstance(raw, list):
        return [item for item in raw if isinstance(item, dict)]
    mapping = as_map(raw)
    if "group" in mapping or "interface" in mapping:
        return [mapping]
    return [value for value in mapping.values() if isinstance(value, dict)]


def group_domains(groups: dict[str, Any], name: str) -> list[str]:
    body = groups.get(name) or {}
    return include_addresses(prop(body, "include") if isinstance(body, dict) else None)


def find_group(groups: dict[str, Any], hint: str) -> str | None:
    for name, body in groups.items():
        if name.lower() == hint.lower():
            return name
        if isinstance(body, dict):
            desc = str(prop(body, "description") or "")
            if desc.lower() == hint.lower():
                return name
    return None


def next_list_name(groups: dict[str, Any]) -> str:
    index = 0
    while f"domain-list{index}" in groups:
        index += 1
    return f"domain-list{index}"


def group_has_route(routes: list[dict[str, Any]], name: str) -> bool:
    for route in routes:
        group = prop(route, "group", "object-group", "Group")
        if group and str(group).lower() == name.lower():
            return True
    return False


def diagnose_text(
    version: dict[str, Any],
    wan: dict[str, Any] | None,
    vpn: dict[str, Any] | None,
    instagram: dict[str, Any],
    cursor: dict[str, Any],
) -> str:
    model = str(prop(version, "model") or "")
    title = str(prop(version, "title") or "")
    lines = [
        f"Роутер: {(model + ' ' + title).strip() or 'Keenetic'}",
        f"WAN: {wan['id'] if wan else 'не найден'}"
        + ("" if not wan else (" — работает" if wan["up"] else " — лежит")),
        f"VPN: {vpn['id'] if vpn else 'нет'}"
        + (
            ""
            if not vpn
            else (
                f" ({vpn['description']})" if vpn.get("description") else ""
            )
            + (" — поднят" if vpn["up"] else " — лежит")
        ),
        f"Instagram: {instagram['name']} · {instagram['have']}/{instagram['total']} доменов",
        f"Cursor: {cursor['name']} · {cursor['have']}/{cursor['total']} доменов",
    ]
    return "\n".join(lines)


def ensure_group(
    client: Keenetic,
    groups: dict[str, Any],
    routes: list[dict[str, Any]],
    hint: str,
    domains: list[str],
    vpn_id: str,
) -> dict[str, Any]:
    name = find_group(groups, hint) or hint
    created = name not in groups
    have = set(group_domains(groups, name))
    missing = [domain for domain in domains if domain not in have]

    def apply(target: str, new_domains: list[str], is_new: bool) -> None:
        if is_new or new_domains:
            include = [{"address": domain} for domain in (domains if is_new else new_domains)]
            inner: dict[str, Any] = {}
            if is_new:
                inner["description"] = hint
            if include:
                inner["include"] = include
            client.rci([{"object-group": {"fqdn": {target: inner}}}])
        if not group_has_route(routes, target):
            client.parse(f"dns-proxy route object-group {target} {vpn_id} auto")
            routes.append({"group": target, "interface": vpn_id})

    try:
        apply(name, missing, created)
    except RouterError:
        if not created:
            raise
        name = next_list_name(groups)
        apply(name, domains, True)
        missing = list(domains)
    groups[name] = {"description": hint, "include": [{"address": d} for d in have.union(missing)]}
    return {"name": name, "added": len(missing), "total": len(domains), "have": len(have | set(missing))}


def collect_state(client: Keenetic) -> dict[str, Any]:
    version_raw = client.show("version")
    version = version_raw if isinstance(version_raw, dict) else {}
    ifaces_raw = client.show("interface")
    interfaces = as_map(ifaces_raw)
    groups = as_map(client.get("object-group/fqdn") or client.show("sc", "object-group", "fqdn") or {})
    routes = normalize_routes(client.get("dns-proxy/route") or client.show("sc", "dns-proxy", "route"))
    vpn = pick_vpn(interfaces, preferred_route_iface(routes))
    wan = pick_wan(interfaces)
    return {
        "version": version,
        "interfaces": interfaces,
        "groups": groups,
        "routes": routes,
        "vpn": vpn,
        "wan": wan,
    }


def restore_wan_policy(client: Keenetic, wan: dict[str, Any]) -> str | None:
    try:
        client.parse("no ip hotspot policy")
        return "Политика хотспота сброшена на default (интернет через провайдера)."
    except RouterError:
        try:
            client.parse(f"ip policy default permit global {wan['id']}")
            return f"В default-политику добавлен {wan['id']}."
        except RouterError:
            return None


def run_fix(args: argparse.Namespace) -> int:
    password = read_password(args.password)
    client = Keenetic(args.host, args.user, password, timeout=args.timeout)
    client.connect()

    instagram = load_domains(
        os.path.join(script_dir(), "vpn", "instagram-domains.txt"), FALLBACK_INSTAGRAM
    )
    cursor = load_domains(os.path.join(script_dir(), "vpn", "cursor-domains.txt"), FALLBACK_CURSOR)

    state = collect_state(client)
    ig_name = find_group(state["groups"], "Instagram") or "Instagram"
    cu_name = find_group(state["groups"], "Cursor") or "Cursor"
    print(
        diagnose_text(
            state["version"],
            state["wan"],
            state["vpn"],
            {
                "name": ig_name,
                "have": len(group_domains(state["groups"], ig_name)),
                "total": len(instagram),
            },
            {
                "name": cu_name,
                "have": len(group_domains(state["groups"], cu_name)),
                "total": len(cursor),
            },
        )
    )

    if args.diagnose:
        return 0

    notes: list[str] = []
    if state["wan"] and not state["wan"]["up"]:
        raise RouterError(
            f"Канал провайдера {state['wan']['id']} лежит. Это не VPN: проверьте кабель/PPPoE в веб-интерфейсе."
        )

    if args.restore_wan and state["wan"]:
        msg = restore_wan_policy(client, state["wan"])
        if msg:
            notes.append(msg)

    if not state["vpn"]:
        raise RouterError(
            "На роутере нет VPN (WireGuard / Amnezia / OpenVPN). "
            "Поднимите туннель в «Интернет → Другие подключения» и запустите скрипт снова."
        )

    if not state["vpn"]["up"]:
        print(f"Поднимаю {state['vpn']['id']}…")
        if not args.dry_run:
            client.set_up(state["vpn"]["id"], True)
            if args.wait > 0:
                time.sleep(args.wait)
            state = collect_state(client)
            if not state["vpn"]:
                raise RouterError("VPN-интерфейс пропал после включения. Проверьте туннель в веб-интерфейсе.")
            if state["vpn"] and not state["vpn"]["up"]:
                notes.append(
                    f"{state['vpn']['id']} всё ещё лежит: проверьте ключи/сервер VPN. "
                    "Пока туннель down, Instagram и Cursor пойдут в никуда."
                )
            else:
                notes.append(f"{state['vpn']['id']} поднят.")

    if args.dry_run:
        print("dry-run: группы и маршруты не менялись.")
        return 0

    ig = ensure_group(client, state["groups"], state["routes"], "Instagram", instagram, state["vpn"]["id"])
    cu = ensure_group(client, state["groups"], state["routes"], "Cursor", cursor, state["vpn"]["id"])
    client.save()
    notes.append(f"Instagram ({ig['name']}): +{ig['added']} доменов")
    notes.append(f"Cursor ({cu['name']}): +{cu['added']} доменов")
    notes.append("Конфигурация сохранена.")
    notes.append("На телефонах DNS = автоматически с роутера, Private DNS / DoH выключить.")

    if args.reboot:
        print("Перезагружаю роутер: без reboot Keenetic часто не применяет dns-proxy route.")
        client.reboot()
        notes.append("Роутер перезагружается, интернет вернётся через 1–2 минуты.")

    print("\n".join(notes))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Починить Keenetic: VPN + Instagram/Cursor")
    parser.add_argument("--host", default=os.environ.get("KEENETIC_HOST", DEFAULT_HOST))
    parser.add_argument("--user", default=os.environ.get("KEENETIC_LOGIN", DEFAULT_USER))
    parser.add_argument("--password", default=None, help="лучше KEENETIC_PASSWORD")
    parser.add_argument("--diagnose", action="store_true", help="только показать состояние")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-reboot", dest="reboot", action="store_false")
    parser.add_argument("--reboot", dest="reboot", action="store_true")
    parser.add_argument("--restore-wan", action="store_true", default=True)
    parser.add_argument("--no-restore-wan", dest="restore_wan", action="store_false")
    parser.add_argument("--timeout", type=float, default=12.0)
    parser.add_argument("--wait", type=float, default=2.0, help="pause after bringing VPN up")
    parser.add_argument("--print-domains", action="store_true")
    parser.set_defaults(reboot=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.print_domains:
        instagram = load_domains(
            os.path.join(script_dir(), "vpn", "instagram-domains.txt"), FALLBACK_INSTAGRAM
        )
        cursor = load_domains(os.path.join(script_dir(), "vpn", "cursor-domains.txt"), FALLBACK_CURSOR)
        print("Instagram:")
        print("\n".join(instagram))
        print("Cursor:")
        print("\n".join(cursor))
        return 0
    try:
        return run_fix(args)
    except RouterError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
