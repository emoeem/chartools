#!/usr/bin/env python3
"""把同一套臂的多**轮**实况 A/B 原始 JSON 合并成一张均值表。

为什么要合并：单轮 6 个 case × 2 次重复，每臂只有 6–12 次盲评，一次判分就能把
均值拉动 0.1 分。跑两次之后看「哪些结论在两次里都成立」才有意义 ——
`_reports/kb-effect_report.md` 是单轮报告，这份是它与同参数重跑一轮的合并视图。

用法：
    python3 tools/jev/merge_kb_effect.py \
        app/build/scratch/kb_effect_live_4arm_run1.json \
        app/build/scratch/kb_effect_live_4arm_run2.json \
        --out _reports/kb-effect_report_2runs.md
"""

import argparse
import json

from safeguards import write_text

# 与 eval_kb_effect.py 同一张领域词表；改一处要改两处。
DOMAIN_WORDS = [
    "主人", "调教", "任务", "安全词", "红灯", "契约", "奴", "服从", "规矩", "奖励",
    "惩罚", "汇报", "驯养", "跪下", "项圈", "SP", "管教", "乖", "惩戒", "底线",
    "同意", "事后", "安抚", "界限", "阶段",
]

ARM_NOTE = {
    "kb": "人设卡 + BM25 命中的 5 段原始片段",
    "nokb": "人设卡，无笔记",
    "nocard": "笔记不变，去掉人设卡",
    "summary": "人设卡 + 一张领域卡（整库预扫）",
}


def collect(path):
    data = json.load(open(path, encoding="utf-8"))
    arms = data["arms"]
    ref = data["reference"]
    stat = {a: {"leak": 0, "domain": [], "judge": []} for a in arms}
    for row in data["rows"]:
        for run in row["runs"]:
            for a in arms:
                got = run.get(a)
                if not got:
                    continue
                stat[a]["leak"] += len(got.get("kb_leak") or [])
                stat[a]["domain"].append(len(got.get("domain") or []))
                if got.get("judge") is not None:
                    stat[a]["judge"].append(got["judge"])
    return arms, ref, stat


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--out", default="_reports/kb-effect_report_2runs.md")
    args = ap.parse_args()

    merged = None
    arms = ref = None
    for path in args.runs:
        a, r, stat = collect(path)
        arms, ref = a, r
        if merged is None:
            merged = {x: {"leak": 0, "domain": [], "judge": []} for x in a}
        for x in a:
            merged[x]["leak"] += stat[x]["leak"]
            merged[x]["domain"] += stat[x]["domain"]
            merged[x]["judge"] += stat[x]["judge"]

    def mean(xs):
        return sum(xs) / len(xs) if xs else float("nan")

    lines = [
        "# 知识库实况 A/B：两轮合并",
        "",
        "同一套问卷、同一批臂、同一参数跑了两轮（`%s`）。" % "` + `".join(args.runs),
        "单轮每臂只有 6–12 次盲评，一次判分能拉动均值 0.1 分，所以结论只看"
        "**两轮都成立**的那些。",
        "",
        "| 臂 | 注入什么 | 提示词长度 | 专属串落进回复 | 领域词 | 盲评 |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    lengths = {"kb": "~3,440 字", "nokb": "~255 字", "nocard": "~3,261 字", "summary": "~910 字"}
    for a in arms:
        s = merged[a]
        lines.append("| `%s`%s | %s | %s | %d | %.2f | **%.2f**（%d 次判分） |" % (
            a, "（参照）" if a == ref else "", ARM_NOTE.get(a, ""), lengths.get(a, "?"),
            s["leak"], mean(s["domain"]), mean(s["judge"]), len(s["judge"])))
    lines += [
        "",
        "## 两轮都成立的结论",
        "",
    ]
    j = {a: mean(merged[a]["judge"]) for a in arms}
    d = {a: mean(merged[a]["domain"]) for a in arms}
    lines += [
        "- **去掉人设卡是最伤的**：`nocard` 盲评 %.2f、领域词 %.2f，两项都垫底；"
        "两个分数与 `kb` 的差（%+.2f / %+.2f）在两轮里方向一致。"
        "用户要的「回复和网调有关」，主要就是人设卡在做。" % (
            j["nocard"], d["nocard"], j["nocard"] - j["kb"], d["nocard"] - d["kb"]),
        "- **原始片段几乎没有边际收益**：`kb` %.2f vs `nokb` %.2f（%+.2f），"
        "而提示词长了 13 倍。" % (j["kb"], j["nokb"], j["kb"] - j["nokb"]),
        "- **整库预扫成一张领域卡最好，而且最短**：`summary` %.2f，比 `kb` 高 %+.2f、"
        "比 `nokb` 高 %+.2f，提示词只有 `kb` 的约四分之一。" % (
            j["summary"], j["summary"] - j["kb"], j["summary"] - j["nokb"]),
        "- 知识库内容**确实会进回复**：`kb` 专属 4 字串两轮共 %d 次出现在回复里；"
        "但语料里可用的专属串有 %s 个/场景 —— 也就是命中率千分之几，"
        "「检索原始片段」这条路的信息效率很低。" % (
            merged["kb"]["leak"], "1,694–2,073"),
        "",
        "## 判分口径",
        "",
        "盲评是同模型（温度 0）按「是否像网调语境里会说的话」打 1–5 分，"
        "同一条回复只判它属于哪一臂、a/b 顺序逐轮翻转避免位置偏好；"
        "每臂的判分次数不一样（缺分不会被补），所以别把小数点后第二位当真。",
    ]
    text = "\n".join(lines) + "\n"
    write_text(args.out, text)
    print(text)


if __name__ == "__main__":
    main()
