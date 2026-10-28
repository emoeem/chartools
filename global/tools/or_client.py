"""OpenRouter client for development checks. Standard library only.

The key is read from the OPENROUTER_API_KEY environment variable, or from
~/.config/jev/openrouter.env (either `OPENROUTER_API_KEY=<key>` or a bare key
on one line). It is never printed, logged, or written to disk.

Every call appends one line (route, model, tokens, cost, latency) to
_reports/ledger.jsonl so spend can be checked against the agreed cap.
"""
from __future__ import annotations

import ipaddress
import json
import os
import pathlib
import socket
import time
import urllib.error
import urllib.parse
import urllib.request

DECISIONS_URL = "https://openrouter.ai/api/alpha/decisions"
CHAT_URL = "https://openrouter.ai/api/v1/chat/completions"
JEV_MODEL = "typesafe/jev-1.13"
DRAFT_MODEL = "deepseek/deepseek-chat-v3.1"
HEADERS = {"HTTP-Referer": "https://jev-assistant.local", "X-Title": "Jev Assistant"}

ROOT = pathlib.Path(__file__).resolve().parents[2]
LEDGER = ROOT / "_reports" / "ledger.jsonl"


class ApiError(Exception):
    def __init__(self, status, body):
        super().__init__(f"HTTP {status}: {body[:600]}")
        self.status = status
        self.body = body


def _key() -> str:
    key = (os.environ.get("OPENROUTER_API_KEY") or "").strip()
    if key:
        return key
    path = pathlib.Path.home() / ".config" / "jev" / "openrouter.env"
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            line = line.split("=", 1)[1]
        return line.strip().strip('"').strip("'")
    raise RuntimeError("No OpenRouter key found")


def _redact(text: str) -> str:
    try:
        return text.replace(_key(), "[REDACTED]")
    except Exception:
        return text


def _check_url(url: str) -> str:
    """钉死 http(s)，且主机名解析后不许落进内网/回环段。

    DECISIONS_URL / CHAT_URL 是写死的 openrouter 常量，这一道是为以后改配置
    或换 endpoint 时兜底：urlopen 对 file:// 照单全收，DNS 被带进内网段也要拦。
    显式写 IP 或 localhost 算操作者点名，放行。
    """
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme.lower() not in ("http", "https"):
        raise SystemExit(f"只允许 http/https 接口，收到：{url}")
    host = parsed.hostname or ""
    if not host:
        raise SystemExit(f"接口地址缺主机名：{url}")
    try:
        ipaddress.ip_address(host)
        return url
    except ValueError:
        pass
    if host.lower() == "localhost":
        return url
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        raise SystemExit(f"接口主机解析失败 {host}：{exc}")
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if (ip.is_private or ip.is_loopback or ip.is_link_local or
                ip.is_reserved or ip.is_multicast or ip.is_unspecified):
            raise SystemExit(f"接口主机 {host} 解析到非公网地址 {ip}，拒绝请求")
    return url


def _request(url: str, payload: dict | None, timeout: float) -> dict:
    url = _check_url(url)
    data = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    headers = {"Authorization": f"Bearer {_key()}", "Accept": "application/json", **HEADERS}
    if data is not None:
        headers["Content-Type"] = "application/json; charset=utf-8"
    req = urllib.request.Request(url, data=data, method="GET" if data is None else "POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = _redact(exc.read().decode("utf-8", errors="replace"))
        raise ApiError(exc.code, body) from None


def _log(route: str, model: str, started: float, usage: dict | None, ok: bool) -> None:
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    entry = {
        "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "route": route,
        "model": model,
        "ok": ok,
        "seconds": round(time.time() - started, 2),
        "usage": usage or {},
    }
    with LEDGER.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry) + "\n")


def decisions(state: dict, questions: dict, model: str = JEV_MODEL, timeout: float = 60) -> dict:
    started = time.time()
    try:
        body = _request(DECISIONS_URL, {"model": model, "state": state, "questions": questions}, timeout)
    except Exception:
        _log("decisions", model, started, None, False)
        raise
    _log("decisions", model, started, body.get("usage"), True)
    return body


def chat(messages: list, model: str = DRAFT_MODEL, timeout: float = 90, **extra) -> dict:
    started = time.time()
    try:
        body = _request(CHAT_URL, {"model": model, "messages": messages, **extra}, timeout)
    except Exception:
        _log("chat", model, started, None, False)
        raise
    _log("chat", model, started, body.get("usage"), True)
    return body


def key_info() -> dict:
    """Usage and limits for the key. Contains no secret."""
    info = _request("https://openrouter.ai/api/v1/key", None, 30).get("data", {})
    return {k: info.get(k) for k in ("usage", "limit", "limit_remaining", "is_free_tier", "usage_daily")}


def spent() -> float:
    total = 0.0
    if LEDGER.exists():
        for line in LEDGER.read_text().splitlines():
            usage = json.loads(line).get("usage") or {}
            total += float(usage.get("cost") or 0)
    return total
