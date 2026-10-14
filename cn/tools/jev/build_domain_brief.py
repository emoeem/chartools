#!/usr/bin/env python3
"""把一整个知识库预扫成**一段**领域卡，而不是每轮塞 5 段原始片段。

为什么要有它：`_reports/kb-effect_report.md` 的实况 A/B 显示，把 BM25 命中的
5 段原始片段（约 3000 字）塞进提示词之后，盲评**没有变好**（4.00 vs 4.43），
而 3000 字里能落进回复的专属串只有 9 个。原始片段顶多是「话题相邻」，
它稀释的是人设 —— 用户要的「回复和网调有关」，靠的是**设定**，不是更多素材。

这个脚本走的是另一条路（和 /home/emo/code/wenyi 的「全书预扫 → 注入每批」
同一个思路）：先把整库采样一遍，让模型写出一张 ≤900 字的领域卡，之后每轮
只注入这一段。锚点少、密度高、不会随话题漂移。

用法：
    JEV_REPLY_KEY=... python3 tools/jev/build_domain_brief.py \
        --kb app/build/scratch/kb_final.json \
        --out app/build/scratch/domain_brief.json \
        --topic 网调
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from eval_roleplay import api_key, post  # noqa: E402

BRIEF_TITLE = "网调领域卡（自动预扫）"

SYSTEM = (
    "你在给一个中文私密角色扮演助手写**领域设定卡**。用户和对方是成年人、自愿、"
    "已经约定好安全词和硬边界。这张卡会被逐字放进每次回复的提示词里，作用是让"
    "回复保持在这个语境的规矩、流程和说法里，而不是给出通用的安慰或说教。\n"
    "你只做归纳：素材里没有的东西不要编。用中文，不要 Markdown 标题符号，"
    "直接分小段写，每段以「词：」开头。"
)

PROMPT = """下面是从一个「{topic}」知识库里按来源均衡采样出来的片段。请把它压缩成一张领域卡。

要求（很严，超了就废）：
1. 总长不超过 900 个汉字。
2. 只写「让回复像这个语境里的话」所必需的东西，分这六段，每段一行到三行：
   角色与关系：谁是什么身份，谁定规矩
   称呼与语气：常用的称呼、说话的口吻和长度
   典型流程：这类对话通常怎么推进（开场／布置／执行／汇报／收尾）
   常用说法：这个领域里高频出现的词和句式（列 15-25 个词即可）
   边界与安全：必须一直遵守的底线、安全词怎么用、事后怎么处理
   不要做什么：最容易让回复「出戏」的几种写法
3. 不要复述具体情节，不要写「根据素材」之类的元话，不要列表符号。
4. 素材里反复出现但只是同一句话说很多遍的，合并成一句。

素材：
----------------
{sample}
----------------
"""


def sample_corpus(notes, topic, budget_chars, per_doc_chars):
    """按来源均衡采样：先按文件名分组，每份文档均匀取几段，总量封顶。"""
    by_doc = {}
    for n in notes:
        if not n.get("enabled", True):
            continue
        tags = n.get("tags") or []
        doc = tags[1] if len(tags) > 1 else (n.get("title") or "")
        by_doc.setdefault(doc, []).append(n)

    chunk = 400  # 每段只取开头这么多字，够看出在讲什么
    picked = []
    for doc, items in sorted(by_doc.items(), key=lambda kv: -len(kv[1])):
        take = max(1, per_doc_chars // chunk)
        step = max(1, len(items) // take)
        picked.append("### 来源：%s（共 %d 段）" % (doc, len(items)))
        for i in range(0, len(items), step):
            if len(picked) * chunk > budget_chars:
                break
            body = (items[i].get("content") or "")[:chunk]
            picked.append(body)
        if len(picked) * chunk > budget_chars:
            break
    return "\n".join(picked)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kb", default="app/build/scratch/kb_final.json")
    ap.add_argument("--out", default="app/build/scratch/domain_brief.json")
    ap.add_argument("--topic", default="网调")
    ap.add_argument("--base", default=os.environ.get("JEV_REPLY_BASE", "https://api.deepseek.com/v1"))
    ap.add_argument("--model", default=os.environ.get("JEV_REPLY_MODEL", "deepseek-chat"))
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--budget-chars", type=int, default=24000)
    ap.add_argument("--per-doc-chars", type=int, default=1600)
    args = ap.parse_args()

    key = api_key()
    if not key:
        print("no API key: export JEV_REPLY_KEY", file=sys.stderr)
        return 2

    notes = json.load(open(args.kb, encoding="utf-8"))
    sample = sample_corpus(notes, args.topic, args.budget_chars, args.per_doc_chars)
    print("知识库 %d 条；采样 %d 字" % (len(notes), len(sample)))

    body = {
        "model": args.model,
        "temperature": 0.3,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": PROMPT.format(topic=args.topic, sample=sample)},
        ],
    }
    resp = post(args.base, key, body, args.timeout)
    text = (resp.get("choices") or [{}])[0].get("message", {}).get("content", "").strip()
    if not text:
        print("空回复：%s" % json.dumps(resp, ensure_ascii=False)[:400], file=sys.stderr)
        return 1

    han = sum(1 for ch in text if "\u4e00" <= ch <= "\u9fff")
    print("领域卡 %d 字符（汉字 %d）" % (len(text), han))

    note = {
        "id": "domainbrief01",
        "title": BRIEF_TITLE,
        "type": "note",
        "alwaysOn": True,
        "content": text,
        "enabled": True,
        "tags": ["领域卡", args.topic],
        "updatedAt": 1760000000000,
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump([note], f, ensure_ascii=False)
    print("写出 %s" % args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
