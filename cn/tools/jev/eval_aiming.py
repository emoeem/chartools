#!/usr/bin/env python3
"""指向性评测的第二层：把 fixtures/aiming_set.json 的用例真的发给回复模型跑一遍。

第一层是 app/src/test/java/com/jev/probe/jev/AimingFixtureTest.kt：同一份 fixture，
在 JVM 里断言闸门结论和两段提示词里必须出现／绝不能出现什么，不需要网络，每次
`gradlew :app:testDebugUnitTest` 都会跑。

这一层负责离线测不了的那半：模型实际写出来的回复守不守规矩。它自己**不拼提示词**，
而是先让 Gradle 跑 AimingFixtureTest 并 `-Daiming.dump=<path>` 把 PromptDumpTest 里
真正用于生产的两段提示词导出来（ReplyPrompt 是唯一的拼装者），再把这些提示词原样
POST 出去。所以这一层测的一定是 app 的提示词，不会因为它自己另写一套而漂移。

只用标准库。密钥从环境变量读，永远不打印、不落盘。

用法：
    export JEV_REPLY_KEY=...            # 或 DEEPSEEK_API_KEY / OPENROUTER_API_KEY
    python3 tools/jev/eval_aiming.py --base https://api.deepseek.com/v1 --model deepseek-chat
    python3 tools/jev/eval_aiming.py --offline     # 只跑 Gradle 那一层并打印用例

退出码：0 = 硬规矩全过；1 = 有硬规矩没过或请求出错；2 = 环境/参数问题。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

from safeguards import check_http_url

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURE = os.path.join(REPO, "tools", "jev", "fixtures", "aiming_set.json")
DEFAULT_DUMP = os.path.join(REPO, "app", "build", "aiming_prompts.json")
KEY_ENVS = ("JEV_REPLY_KEY", "DEEPSEEK_API_KEY", "OPENROUTER_API_KEY")
GRADLE = ["bash", "gradlew", ":app:testDebugUnitTest", "--tests", "*AimingFixtureTest*"]


def redact(text: str) -> str:
    """Strip the live key from anything about to be printed."""
    for env in KEY_ENVS:
        key = os.environ.get(env) or ""
        if key:
            text = text.replace(key, "[REDACTED]")
    return text


def api_key() -> str:
    for env in KEY_ENVS:
        key = (os.environ.get(env) or "").strip()
        if key:
            return key
    return ""


def dump_prompts(path: str) -> None:
    """Ask the JVM tests for the prompts they evaluate, so both layers agree."""
    cmd = GRADLE + ["-Daiming.dump=" + path, "--console=plain", "-q"]
    print("$ " + " ".join(cmd))
    proc = subprocess.run(cmd, cwd=REPO)
    if proc.returncode != 0:
        raise SystemExit("gradle dump failed (exit %d)" % proc.returncode)
    if not os.path.isfile(path):
        raise SystemExit(
            "gradle ran but %s was not written — check that app/build.gradle.kts still "
            "forwards -Daiming.dump to the test JVM" % path
        )


def candidates(content: str) -> list[dict]:
    """The same parse the app does: the JSON array, else one candidate per line."""
    text = content.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    start, end = text.find("["), text.rfind("]")
    if start >= 0 and end > start:
        try:
            arr = json.loads(text[start:end + 1])
            out = []
            for item in arr:
                if isinstance(item, dict) and str(item.get("text", "")).strip():
                    out.append({
                        "strategy": str(item.get("strategy", "safe")),
                        "text": str(item["text"]).strip(),
                    })
            if out:
                return out
        except json.JSONDecodeError:
            pass
    return [{"strategy": "safe", "text": line.strip()} for line in text.splitlines() if line.strip()]


def ask(base: str, model: str, key: str, system: str, user: str, timeout: float, temperature: float) -> list[dict]:
    body = json.dumps(
        {
            "model": model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "temperature": temperature,
        },
        ensure_ascii=False,
    ).encode("utf-8")
    url = check_http_url(base.rstrip("/") + "/chat/completions")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + key,
            "Accept": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = json.loads(resp.read().decode("utf-8", errors="replace"))
    content = payload["choices"][0]["message"]["content"]
    return candidates(content)


def non_space_len(text: str) -> int:
    return len(re.sub(r"\s+", "", text))


def score(case: dict, replies: list[dict]) -> tuple[list[str], list[str]]:
    """Returns (hard failures, soft warnings) for one case's replies."""
    expect = case.get("expect", {})
    hard, soft = [], []
    texts = [r["text"] for r in replies]
    if not texts:
        return ["模型没有给出任何候选"], []

    for word in expect.get("reply_absent", []) or []:
        hit = [t for t in texts if word in t]
        if hit:
            hard.append("不该出现「%s」却出现了：%s" % (word, hit[0]))

    limit = expect.get("reply_max_chars")
    if limit:
        over = [(t, non_space_len(t)) for t in texts if non_space_len(t) > limit]
        if over:
            hard.append("超出 %d 字上限：%s（%d 字）" % (limit, over[0][0], over[0][1]))

    if len(replies) != 3:
        soft.append("候选数 %d，期望 3 条" % len(replies))
    strategies = [r["strategy"] for r in replies]
    if len(set(strategies)) != len(strategies):
        soft.append("策略有重复：%s" % strategies)
    return hard, soft


def main() -> int:
    ap = argparse.ArgumentParser(description="指向性评测（live layer）")
    ap.add_argument("--base", default=os.environ.get("JEV_REPLY_BASE", "https://api.deepseek.com/v1"),
                    help="OpenAI 兼容端点，默认 DeepSeek")
    ap.add_argument("--model", default=os.environ.get("JEV_REPLY_MODEL", "deepseek-chat"))
    ap.add_argument("--temperature", type=float, default=0.9, help="与 app 默认的 replyTemperature 接近")
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--dump", default=DEFAULT_DUMP, help="Gradle 导出的提示词路径")
    ap.add_argument("--prompt-file", help="复用已有的 dump，不再跑 Gradle")
    ap.add_argument("--offline", action="store_true", help="只跑 Gradle 那一层，不联网")
    ap.add_argument("--fixture", default=FIXTURE)
    args = ap.parse_args()

    if args.prompt_file:
        dump = args.prompt_file
    else:
        dump_prompts(args.dump)
        dump = args.dump

    with open(dump, encoding="utf-8") as fh:
        dumped = {c["id"]: c for c in json.load(fh)}
    with open(args.fixture, encoding="utf-8") as fh:
        cases = json.load(fh)["cases"]

    if args.offline:
        for case in cases:
            d = dumped.get(case["id"], {})
            print("%-34s gate=%-7s %s" % (case["id"], d.get("gate", "?"), case["why"][:38]))
        print("\n离线层：%d 个用例的闸门与提示词已由 AimingFixtureTest 断言。" % len(cases))
        return 0

    key = api_key()
    if not key:
        print(
            "no API key: export JEV_REPLY_KEY (or DEEPSEEK_API_KEY / OPENROUTER_API_KEY). "
            "Keep it in the environment; never write it into a file.",
            file=sys.stderr,
        )
        return 2
    hard_total = soft_total = ran = 0
    for case in cases:
        d = dumped.get(case["id"])
        if not d:
            print("!! %s 没有 dump" % case["id"])
            hard_total += 1
            continue
        if d["gate"] == "block":
            print("[跳过] %-32s 闸门拦下：%s" % (case["id"], d.get("blockReason")))
            continue
        ran += 1
        try:
            replies = ask(args.base, args.model, key, d["system"], d["user"], args.timeout, args.temperature)
        except urllib.error.HTTPError as exc:
            print("!! %-32s HTTP %s %s" % (case["id"], exc.code, redact(exc.read().decode("utf-8", "replace"))[:200]))
            hard_total += 1
            continue
        except Exception as exc:  # noqa: BLE001 - network shape varies; report and continue
            print("!! %-32s %s" % (case["id"], redact(repr(exc))[:200]))
            hard_total += 1
            continue

        hard, soft = score(case, replies)
        hard_total += len(hard)
        soft_total += len(soft)
        mark = "PASS" if not hard else "FAIL"
        print("\n[%s] %s" % (mark, case["id"]))
        print("   场景：%s" % case["why"])
        for r in replies:
            print("   - (%s) %s" % (r["strategy"], r["text"]))
        for item in hard:
            print("   ✗ %s" % item)
        for item in soft:
            print("   · %s" % item)

    print("\n跑过的用例：%d／%d（被闸门拦下的没发出去）" % (ran, len(cases)))
    print("硬规矩失败：%d；提示（候选数/策略）：%d" % (hard_total, soft_total))
    print("模型：%s @ %s" % (args.model, args.base))
    return 1 if hard_total else 0


if __name__ == "__main__":
    sys.exit(main())
