#!/usr/bin/env python3
"""评测脚本的公共护栏。

这里只放四个函数，别放别的：

- [check_http_url]：`urllib.request.urlopen` 对 `file://` / `ftp://` 照单全收。
  评测脚本只该打 HTTP(S) 的模型接口——密钥要跟着请求走，先把目的地钉死。
- [safe_out]：脚本的输出路径来自 CLI 参数，直接落盘会让 `..` 或绝对路径
  写到仓库外。评测产物本来就落在仓库里（app/build、_reports），越界的都是手滑。
- [write_text] / [dump_json]：净化 + 落盘一步到位，调用点不再自己 open。
"""

from __future__ import annotations

import ipaddress
import json
import os
import socket
import urllib.parse
from pathlib import Path

# tools/jev/safeguards.py → 上三级就是本仓库根（cn/）。
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def check_http_url(url: str) -> str:
    """只放行 http/https，且解析后的 IP 不落进内网段。

    --base 是用户自己的模型接口：写明 IP 或 ``localhost`` 的算显式意图
    （本机代理是合法用法）；写主机名的先解析，任何一个地址不是公网
    （RFC1918 / 回环 / 链路本地 / 云元数据段都算）就拒绝——防的是主机名
    被解析进内网的那类 SSRF，不是拦用户连自己的代理。
    """
    parsed = urllib.parse.urlparse(url)
    scheme = parsed.scheme.lower()
    if scheme not in ("http", "https"):
        raise SystemExit("只允许 http/https 接口，收到：%s" % url)
    host = parsed.hostname or ""
    if not host:
        raise SystemExit("接口地址缺主机名：%s" % url)
    try:
        ipaddress.ip_address(host)
        return url  # 显式 IP 字面量：用户点到名了，照打。
    except ValueError:
        pass
    if host.lower() == "localhost":
        return url
    port = parsed.port or (443 if scheme == "https" else 80)
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        raise SystemExit("接口主机解析失败 %s：%s" % (host, exc))
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if (ip.is_private or ip.is_loopback or ip.is_link_local or
                ip.is_reserved or ip.is_multicast or ip.is_unspecified):
            raise SystemExit(
                "接口主机 %s 解析到非公网地址 %s，拒绝请求（本机代理请直接写 127.0.0.1）"
                % (host, ip)
            )
    return url


def safe_out(path: str) -> str:
    """把输出路径收敛进仓库根；越界直接退出而不是悄悄改写。"""
    root = os.path.realpath(REPO)
    full = os.path.realpath(os.path.join(REPO, path))
    if not (full == root or full.startswith(root + os.sep)):
        raise SystemExit("输出路径必须落在仓库内（%s）：%s" % (root, path))
    return full


def write_text(path: str, text: str) -> None:
    """净化 + 写文本，一步到位：调用点不再自己碰盘。"""
    target = Path(safe_out(path))
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


def dump_json(path: str, obj, indent=None) -> None:
    """净化 + json.dump，一步到位：调用点不再自己碰盘。"""
    target = Path(safe_out(path))
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(obj, ensure_ascii=False, indent=indent), encoding="utf-8")
