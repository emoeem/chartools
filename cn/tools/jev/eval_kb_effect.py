#!/usr/bin/env python3
"""知识库「有没有真的进到回复里」的实况 A/B。

背景：这个 app 的知识库注入链有三段 —— 检索（`ContextBuilder.matchNotes`）、
拼装（`ReplyPrompt.draftUserPrompt`）、模型。前两段有单测钉住，第三段从来没测过。
`eval_roleplay.py` 也测不了：那个 fixture 的 `ChatContext` 里只有台账、没有笔记。
于是「知识库有用」一直只是一句设计意图。

做法：`KbEffectProbeTest` 用 app 自己的检索和拼装导出两臂提示词 —— 同一段对话、
同一个人设卡、同一个 system，**唯一的差别是 `ChatContext` 里有没有笔记**。本脚本
把两臂都发给同一个模型、同一个温度，然后数三件事：

  M1 KB 专属串：只出现在注入笔记里、不出现在对照臂提示词里的 4 字串，
     有多少落进了回复。这是「模型说了它本来不可能知道的话」的直接证据。
  M2 领域词：回复里网调语境词的数量。这是用户真正问的那件事 ——
     「回复的内容和网调有关」。
  M3 盲评：把两臂回复打乱顺序交给同一模型，按「是否像网调语境里会说的话」1-5 打分。

两臂温度、模型、提示词长度以外的输入完全相同；每个 case 重复 `--repeat` 次，
因为温度 0.9 下单次差异里噪声占比不小 —— 只报一次会把噪声当成知识库的功劳。

用法：
    export JEV_REPLY_KEY=...        # 或 DEEPSEEK_API_KEY / OPENROUTER_API_KEY
    python3 tools/jev/eval_kb_effect.py --arms app/build/scratch/kb_effect_arms.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from eval_roleplay import api_key, parse_candidates, post, redact  # noqa: E402

DEFAULT_ARMS = os.path.join("app", "build", "scratch", "kb_effect_arms.json")
DEFAULT_OUT = os.path.join("_reports", "kb-effect_report.md")

# 「像不像网调语境里说出来的话」用的领域词。不是判分，只是可数的现场。
DOMAIN_WORDS = [
    "主人", "调教", "任务", "安全词", "红灯", "契约", "奴", "服从", "规矩", "奖励",
    "惩罚", "汇报", "驯", "驯养", "跪下", "项圈", "鞭", "sp", "SP", "管教", "命令",
    "乖", "惩戒", "规矩", "底线", "同意", "事后", "安抚", "界限", "阶段",
]

JUDGE_RUBRIC = """你在帮我做一次盲评。下面是同一个人的两段聊天回复，分别由两个版本的应用给出，我不告诉你哪个是哪个。

背景：我正在跟对方做「网调」（字母圈 / 线上调教，双方自愿、有安全词）。我需要的回复是**在这个语境里说得出口的话**，而不是通用的安慰或客服口吻，也不是脱离语境的空话。

请只看这两段回复，各打一个 1-5 分：
5 = 完全在网调语境里，像真主人/真奴在说话，具体、有分寸、可以直接发出去
3 = 大体对味，但偏泛、偏说明书，或者像在讲道理
1 = 完全跑偏，像通用助手在安慰人，跟网调没关系

只输出 JSON，不要别的：
{"a":{"score":<1-5>,"why":"<20字内>"},"b":{"score":<1-5>,"why":"<20字内>"}}"""


def ngrams(text: str, n: int = 4) -> set[str]:
    """汉字 4-gram，空白和标点先去掉 —— 和 `LexicalSearch` 的汉字 bigram 同源，只是更长。"""
    t = re.sub(r"[^\u4e00-\u9fffA-Za-z0-9]", "", text or "")
    if len(t) < n:
        return {t} if t else set()
    return {t[i:i + n] for i in range(len(t) - n + 1)}


def kb_exclusive(notes: list[dict], other_prompt: str) -> set[str]:
    """只在注入笔记里出现、对照臂提示词里一个字都没有的 4 字串。"""
    seen = ngrams(other_prompt)
    out: set[str] = set()
    for h in notes:
        for g in ngrams(h.get("content") or ""):
            if g not in seen:
                out.add(g)
    return out


def domain_hits(text: str) -> list[str]:
    return [w for w in DOMAIN_WORDS if w in (text or "")]


def all_reply_text(cands: list[dict]) -> str:
    return "\n".join(c.get("text", "") for c in cands)


def parse_judge(content: str) -> dict | None:
    m = re.search(r"\{.*\}", content or "", re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except json.JSONDecodeError:
        return None
    return d if "a" in d and "b" in d else None


def main() -> int:
    ap = argparse.ArgumentParser(description="知识库实况效果 A/B")
    ap.add_argument("--arms", default=DEFAULT_ARMS)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--raw", default=os.path.join("app", "build", "scratch", "kb_effect_live.json"))
    ap.add_argument("--base", default=os.environ.get("JEV_REPLY_BASE", "https://api.deepseek.com/v1"))
    ap.add_argument("--model", default=os.environ.get("JEV_REPLY_MODEL", "deepseek-chat"))
    ap.add_argument("--judge-model", default=os.environ.get("JEV_JUDGE_MODEL", ""),
                    help="默认和回复模型相同")
    ap.add_argument("--temperature", type=float, default=0.9)
    ap.add_argument("--repeat", type=int, default=2, help="每个 case 每个臂跑几次（温度 0.9，单次说明不了问题）")
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--no-judge", action="store_true")
    ap.add_argument("--arms-list", default="kb,nokb",
                    help="要跑的臂，逗号分隔；必须都在导出文件里")
    ap.add_argument("--reference", default="kb",
                    help="盲评的参照臂：其余每个臂都只和它成对比较")
    args = ap.parse_args()

    key = api_key()
    if not key:
        print("no API key: export JEV_REPLY_KEY (or DEEPSEEK_API_KEY)", file=sys.stderr)
        return 2
    judge_model = args.judge_model or args.model

    arms = json.load(open(args.arms, encoding="utf-8"))
    by: dict[tuple[str, str], dict] = {(a["id"], a["arm"]): a for a in arms}
    ids: list[str] = []
    for a in arms:
        if a["id"] not in ids:
            ids.append(a["id"])
    if args.only:
        ids = [i for i in ids if i in args.only]
    if not ids:
        print("no cases", file=sys.stderr)
        return 2

    want = [x.strip() for x in args.arms_list.split(",") if x.strip()]
    ref = args.reference
    present = [a for a in want if (ids[0], a) in by]
    if ref not in present:
        print("参照臂 %s 不在导出里（有 %s）" % (ref, present), file=sys.stderr)
        return 2
    others = [a for a in present if a != ref]
    print("臂：%s；参照 %s" % (present, ref))

    rows = []
    for cid in ids:
        have = {a: by.get((cid, a)) for a in present}
        missing = [a for a, v in have.items() if not v]
        if missing:
            print("跳过 %s：缺 %s" % (cid, missing), file=sys.stderr)
            continue
        # 专属串要和**所有**对照臂比：只出现在参照臂注入笔记里的 4 字串。
        #
        # 但只和「笔记不一样的」臂比。`nocard` 臂的笔记和 `kb` 逐字相同（它只换人设
        # 卡），如果把它也算进对照，`kb` 的每一条注入内容都会在它那里「出现过」，
        # 专属串直接归零 —— 实测第一版就是这么把 9 个专属串算成 0 的，看起来像
        # 「知识库没进回复」，其实只是两张提示词里都有同一段笔记。
        ref_hits = have[ref].get("hits") or []
        other_text = "\n".join(
            v["user"] for a, v in have.items()
            if a != ref and (v.get("hits") or []) != ref_hits
        )
        excl = kb_exclusive(have[ref].get("hits") or [], other_text)
        rec = {"id": cid, "kb_exclusive_ngrams": len(excl), "runs": []}
        print("\n=== %s  （%s 专属 4 字串 %d 个）" % (cid, ref, len(excl)))
        for rep in range(args.repeat):
            got = {}
            for arm in present:
                src = have[arm]
                body = {
                    "model": args.model,
                    "temperature": args.temperature,
                    "messages": [
                        {"role": "system", "content": src["system"]},
                        {"role": "user", "content": src["user"]},
                    ],
                }
                resp = post(args.base, key, body, args.timeout)
                content = resp["choices"][0]["message"]["content"]
                cands = parse_candidates(content)
                txt = all_reply_text(cands)
                ng = ngrams(txt)
                got[arm] = {
                    "candidates": cands,
                    "chars": len(re.sub(r"\s+", "", txt)),
                    "kb_leak": sorted(excl & ng),
                    "domain": domain_hits(txt),
                    "text": txt,
                }
            # 盲评：只判「参照臂 vs 另一个臂」，a/b 顺序每轮翻转，避免位置偏好
            # 被算成知识库的功劳。
            if not args.no_judge:
                for k, other in enumerate(others):
                    if (rep + k) % 2 == 1:
                        first, second = other, ref
                    else:
                        first, second = ref, other
                    jbody = {
                        "model": judge_model,
                        "temperature": 0.0,
                        "messages": [{"role": "user", "content": JUDGE_RUBRIC +
                                      "\n\n--- A ---\n" + got[first]["text"] +
                                      "\n\n--- B ---\n" + got[second]["text"]}],
                    }
                    try:
                        jc = post(args.base, key, jbody, args.timeout)["choices"][0]["message"]["content"]
                        jd = parse_judge(jc)
                    except Exception as exc:  # 判分失败不能让整轮白跑
                        print("  judge failed: %s" % redact(str(exc)), file=sys.stderr)
                        jd = None
                    if jd:
                        got[first]["judge"] = jd["a"].get("score")
                        got[second]["judge"] = jd["b"].get("score")
                        got[first]["judge_why"] = jd["a"].get("why")
                        got[second]["judge_why"] = jd["b"].get("why")
            for arm in present:
                g = got[arm]
                print("  [%d] %-8s 字=%3d  %s专属命中=%2d  领域词=%2d  盲评=%s" % (
                    rep, arm, g["chars"], ref, len(g["kb_leak"]), len(g["domain"]),
                    g.get("judge", "—")))
                print("        %s" % g["text"].replace("\n", " / ")[:160])
            rec["runs"].append(got)
        rows.append(rec)

    # ---------- 汇总 ----------
    def mean(xs):
        xs = [x for x in xs if x is not None]
        return sum(xs) / len(xs) if xs else float("nan")

    sb = []
    p = sb.append
    p("# 知识库实况效果 A/B（同一提示词，只有笔记/人设那一块不同）")
    p("")
    p("臂：%s（参照 `%s`）。每个 case 重复 %d 次，温度 %.1f。" % (
        "、".join("`%s`" % a for a in present), ref, args.repeat, args.temperature))
    p("`%s` 专属 4 字串 = 只出现在「%s」臂注入笔记里、其余各臂提示词里都没有的 4 字串。" % (ref, ref))
    p("盲评只判「%s vs 另一个臂」，a/b 顺序逐轮翻转。" % ref)
    p("")
    p("| case | " + " | ".join("%s 专属串" % a for a in present) +
      " | " + " | ".join("%s 领域词" % a for a in present) +
      " | " + " | ".join("%s 盲评" % a for a in present) + " |")
    p("| --- |" + " --- |" * (3 * len(present)))
    tot: dict[str, dict[str, list]] = {a: {"leak": [], "dom": [], "judge": []} for a in present}
    for r in rows:
        cells_leak, cells_dom, cells_j = [], [], []
        for a in present:
            lk = [len(x[a]["kb_leak"]) for x in r["runs"]]
            dm = [len(x[a]["domain"]) for x in r["runs"]]
            jg = [x[a].get("judge") for x in r["runs"]]
            tot[a]["leak"] += lk
            tot[a]["dom"] += dm
            tot[a]["judge"] += jg
            cells_leak.append("/".join(str(x) for x in lk))
            cells_dom.append("%.1f" % mean(dm))
            cells_j.append("%.1f" % mean(jg) if any(j is not None for j in jg) else "—")
        p("| `%s` | %s | %s | %s |" % (r["id"],
                                       " | ".join(cells_leak),
                                       " | ".join(cells_dom),
                                       " | ".join(cells_j)))
    p("")
    p("## 总共")
    p("")
    for a in present:
        p("- `%s`：%s 专属串 %d 次 / 领域词 %.1f 条 / 盲评 %.2f（判分 %d 次）" % (
            a, ref, sum(tot[a]["leak"]), mean(tot[a]["dom"]), mean(tot[a]["judge"]),
            sum(1 for x in tot[a]["judge"] if x is not None)))
    p("")
    p("## 逐轮原文")
    p("")
    for r in rows:
        p("### `%s`" % r["id"])
        p("")
        for h in (by[(r["id"], ref)].get("hits") or []):
            p("- `%s` 注入：`%s`" % (ref, h["title"]))
        p("")
        for i, run in enumerate(r["runs"]):
            p("**第 %d 次**" % (i + 1))
            p("")
            for arm in present:
                g = run[arm]
                p("- `%s`（盲评 %s）：%s" % (arm, g.get("judge", "—"), g["text"].replace("\n", " / ")))
            p("")

    out = "\n".join(sb)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    open(args.out, "w", encoding="utf-8").write(out)
    os.makedirs(os.path.dirname(args.raw), exist_ok=True)
    json.dump({"arms": present, "reference": ref, "rows": rows},
              open(args.raw, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("\n报告：%s" % args.out)
    print("原始：%s" % args.raw)
    print("；".join("%s: 专属串 %d / 领域词 %.1f / 盲评 %.2f" % (
        a, sum(tot[a]["leak"]), mean(tot[a]["dom"]), mean(tot[a]["judge"])) for a in present))
    return 0


if __name__ == "__main__":
    sys.exit(main())
