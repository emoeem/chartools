#!/usr/bin/env python3
"""从 MichengAI/dsh-agency-agents 的 331 位专家，生成 App 的专家目录。

为什么要有这个脚本、而不是手写一个 Kotlin 大文件：
  331 条 × 每条约 300 字 = 十万字。手写不可能维护，塞进 .kt 还会拖慢编译、
  在 APK 里留一份重复数据。所以**生成物是 assets 里的 JSON**，脚本进仓库，
  `--check` 模式校验生成物与上游一致（防止有人手改 JSON 后忘了改脚本）。

为什么不直接把原文（2–8KB 的 agent system prompt）塞进 body：
  body 是唯一进 `promptText()` 的文本。原文是写给「长期干活的智能体」的
  操作手册（工作流程、交付物格式、自检清单），塞进一条聊天回复的提示词里，
  预算会爆、重点会散。这里只提炼**能改变一句话怎么说**的那部分:
  称呼 / 关系 / 语气 / 主题 / 情境 / 三条硬规矩 / 两三句示例。
  完整简介不进提示词，也不落盘 —— 卡片只需要一行简介。

用法：
  python3 tools/gen_experts.py --src /tmp/dsh-agency-agents
  python3 tools/gen_experts.py --src ... --check
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------- 分类映射

#: 上游 22 个 division → App 里的分类抽屉名。顺序即界面 chips 的顺序。
#: 五个老分类排在前面：手写的那 14 张预设还在用它们，不能让老用户找不到自己的卡。
DIVISIONS = [
    ("academic", "学术研究"),
    ("company", "企业战略"),
    ("design", "设计"),
    ("engineering", "技术工程"),
    ("finance", "金融财务"),
    ("game-development", "游戏开发"),
    ("gis", "地理信息"),
    ("healthcare", "医疗健康"),
    ("hr", "人力组织"),
    ("legal", "法务合规"),
    ("marketing", "市场营销"),
    ("paid-media", "投放广告"),
    ("product", "产品"),
    ("project-management", "项目管理"),
    ("research", "研究"),
    ("sales", "销售"),
    ("security", "安全"),
    ("spatial-computing", "空间计算"),
    ("specialized", "垂直专业"),
    ("supply-chain", "供应链"),
    ("support", "客服"),
    ("testing", "质量测试"),
]
DIV_NAME = dict(DIVISIONS)

#: 分类会和 App 的老分类重名（销售 / 客服），重名是**故意**的：
#: 上游 9 位销售专家应该和手写的「销售·跟单」躺在同一个抽屉里。
LEGACY_CATEGORIES = ["情感", "销售", "职场", "客服", "日常"]

MAX_DESC = 46
MAX_RULE = 42
MAX_TONE = 28
MAX_EXAMPLE = 38
MAX_BODY = 720
MAX_TOPIC = 12

# ---------------------------------------------------------------- 文本清洗

EMOJI_RE = re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF"
    "\U00002190-\U000021FF\U00002B00-\U00002BFF\uFE0F\u200d]"
)
BOLD_RE = re.compile(r"\*\*(.+?)\*\*")
CODE_RE = re.compile(r"`([^`]*)`")
LINK_RE = re.compile(r"\[([^\]]*)\]\([^)]*\)")
NUM_RE = re.compile(r"^\s*(?:\d+[.、)]|[-*•+])\s*")

#: 一句「规矩」开头常见的废话，去掉后剩下的才是能照做的话。
FILLER = re.compile(r"^(?:你|请|要|必须|应当|一定|记住|注意)[，,、]?\s*")

#: 段落开头常见的「领域废话」，提炼主题时要去掉。
TOPIC_FILLER = re.compile(r"^(?:精通|专注|擅长|资深|专业|面向|针对|处理|负责|从事|以)")


def clean(line: str) -> str:
    """把一行 markdown 洗成一句人话：去符号、去 emoji、去列表序号。"""
    s = line.strip()
    s = NUM_RE.sub("", s)
    s = s.replace(">", " ")
    s = BOLD_RE.sub(r"\1", s)
    s = CODE_RE.sub(r"\1", s)
    s = LINK_RE.sub(r"\1", s)
    s = EMOJI_RE.sub("", s)
    s = s.replace("——", "，").replace("—", "，")
    s = re.sub(r"[*_#|]+", "", s)
    s = re.sub(r"\s+", " ", s).strip(" ，。;；:：、-")
    return s


def balanced(text: str) -> str:
    """去掉句尾没闭合的引号/括号 —— 截断最容易在这里出丑。"""
    pairs = {'"': '"', "“": "”", "「": "」", "（": "）", "(": ")", "《": "》"}
    out = text
    for opener, closer in pairs.items():
        while out.count(opener) > out.count(closer):
            at = out.rfind(opener)
            if at <= 0:
                break
            out = out[:at].rstrip(" ，。;；、")
    return out


def clip(text: str, limit: int) -> str:
    """按**句子边界**截断：宁可短，不要从词中间砍。"""
    t = balanced(text.strip())
    if len(t) <= limit:
        return t
    cut = -1
    for mark in "。！？；，,;":
        at = t.rfind(mark, 0, limit)
        if at > cut:
            cut = at
    if cut < limit // 3:
        cut = limit
    return balanced(t[:cut].strip(" ，。;；、"))


def section(text: str, *names: str) -> str:
    """取 `## …名字…` 到下一个 `##` 之间的正文。名字按传入顺序找第一个命中的。"""
    for name in names:
        m = re.search(
            r"^##[^\n]*" + re.escape(name) + r"[^\n]*\n(.*?)(?=^##\s|\Z)",
            text,
            re.S | re.M,
        )
        if m:
            return m.group(1)
    return ""


def bullets(block: str) -> list[str]:
    """把一段 markdown 拆成「以列表项/加粗开头」的条目（跳过空行与小标题）。"""
    out = []
    for raw in block.split("\n"):
        s = raw.strip()
        if not s or s.startswith("#") or s.startswith("---"):
            continue
        if NUM_RE.match(s) or s.startswith("**") or s.startswith(">"):
            c = clean(s)
            if len(c) >= 6:
                out.append(c)
    return out


def quotes(block: str) -> list[str]:
    """取 `> "……"` 这类**示例台词**：它们本来就是第一人称说的话。"""
    out = []
    for raw in block.split("\n"):
        s = raw.strip()
        if not s.startswith(">"):
            continue
        c = clean(s).strip("\"“”'‘’「」《》 ")
        if 6 <= len(c) <= 80:
            out.append(c)
    return out


def bold_labels(block: str) -> list[str]:
    """`- **苏格拉底式引导**：用问题引领` → `苏格拉底式引导`。"""
    out = []
    for raw in block.split("\n"):
        for m in BOLD_RE.finditer(raw):
            label = clean(m.group(1))
            if 2 <= len(label) <= 12:
                out.append(label)
    return out


def split_label(text: str) -> tuple[str, str]:
    """`先给出总结：整体印象` → (`先给出总结`, `整体印象`)。没有冒号时前半为空。"""
    for mark in ("：", ":"):
        at = text.find(mark)
        if 0 < at <= 14:
            return text[:at].strip(), text[at + 1:].strip()
    return "", text


# ---------------------------------------------------------------- 提炼正文

SUFFIX = re.compile(
    r"(?:工程师|专家|顾问|架构师|总监|主管|负责人|经理|教练|分析师|设计师|研究员|策略师|规划师|专员|师|官|家)$"
)


def topic_of(name: str, desc: str, category: str) -> str:
    """主题 = 这位专家管的那件事。`动态定价策略师` → `动态定价`，`人类学家` → `人类学`。"""
    t = name
    if t.endswith("学家"):
        t = t[:-2] + "学"
    else:
        t = SUFFIX.sub("", t)
    t = t.strip("·- ")
    if len(t) < 2 or t == name:
        # 名字本身就是一个不可拆的词（`人类学家` 之外的 `统计学家` 之类已覆盖），
        # 退到简介里的第一个名词短语：「文化体系、仪式、亲属关系…」→「文化体系」。
        head = re.split(r"[、，,——/：:；;（(]", desc)[0]
        head = TOPIC_FILLER.sub("", clean(head))
        if 2 <= len(head) <= MAX_TOPIC:
            t = head
        elif len(head) > MAX_TOPIC:
            t = clip(head, MAX_TOPIC)
        else:
            t = category
    # 兜底分支从简介里切出来的短语，去完「精通」这类废话**会留下一个前导空格**
    # （`精通 iOS/Android …` → `" iOS"`），于是 body 里写成 `主题： iOS`，
    # 关系行写成 `在「 iOS」这件事上`。331 位里命中 2 位（移动应用开发者、高级开发者）。
    # `PersonaCard` 解析时会 trim，所以回复不受影响 —— 但正文是给人看的，
    # 而这种瑕疵只会在生成物里悄悄留着。统一在出口 strip 一次。
    return t[:MAX_TOPIC].strip()


def tone_of(text: str, name: str) -> str:
    style = section(text, "沟通风格")
    labels = bold_labels(style)
    if len(labels) >= 2:
        return clip("、".join(labels[:2]), MAX_TONE)
    if labels:
        return clip(labels[0], MAX_TONE)
    for item in bullets(style):
        label, _ = split_label(item)
        if label:
            return clip(label, MAX_TONE)
        if len(item) >= 4:
            return clip(item, MAX_TONE)
    # 上游约 45% 的专家没有「沟通风格」小节 —— 用身份小节里的性格/角色兜底。
    ident = section(text, "你的身份与记忆")
    for raw in ident.split("\n"):
        if "性格" in raw or "角色" in raw:
            c = clean(raw)
            label, rest = split_label(c)
            if label:
                return clip(label, MAX_TONE)
            if len(c) >= 4:
                return clip(c, MAX_TONE)
    return "专业、具体，先说结论再给依据"


def rules_of(text: str) -> list[str]:
    block = section(text, "关键规则", "核心规则")
    items = bullets(block)
    if not items:
        block = section(text, "核心使命")
        items = bullets(block)
    if not items:
        block = section(text, "工作原则", "工作流程")
        items = bullets(block)
    seen, out = set(), []
    for it in items:
        k = FILLER.sub("", clip(it, MAX_RULE))
        if len(k) < 6 or k in seen:
            continue
        # 同一句话里前后半段常常重复（`X。先了解规则再打破规则`），去重后只留前半。
        head = re.split(r"[。；]", k)[0]
        if len(head) >= 8:
            k = head
        if k in seen:
            continue
        seen.add(k)
        out.append(k)
        if len(out) == 3:
            break
    return out


#: 三句「兜底示例」不是凑数：它们在语义上就是这位专家被问到时最可能说的开场。
FALLBACK_EXAMPLES = [
    "先把结论说了，再讲为什么",
    "这块我没把握，我去查实了再回你",
    "要动之前我先跟你说清楚代价",
]


def examples_of(text: str, rules: list[str], topic: str) -> list[str]:
    """示例只学语气和称呼，所以优先用原文里的**真台词**（`> "……"`）。

    绝不复用 `补充` 里的规矩：同一句话在提示词里出现两次（一次当规矩、一次当
    「我本人的说话风格」）会让模型把「陈述纪律」误当成「我的口语」。
    """
    style = section(text, "沟通风格")
    out = quotes(style)[:3]
    if len(out) < 2:
        for item in bullets(style):
            if len(out) >= 2:
                break
            label, rest = split_label(item)
            cand = f"{label}，{rest}" if label and rest else item
            cand = clip(cand, MAX_EXAMPLE)
            if len(cand) >= 6 and cand not in out and cand not in rules:
                out.append(cand)
    pad = [f"这事按{topic}的规矩来：{FALLBACK_EXAMPLES[0]}"] + FALLBACK_EXAMPLES[1:]
    for cand in pad:
        if len(out) >= 2:
            break
        c = clip(cand, MAX_EXAMPLE)
        if c not in out:
            out.append(c)
    return [clip(x, MAX_EXAMPLE) for x in out[:3]]


def body_of(name: str, desc: str, category: str, text: str) -> str:
    topic = topic_of(name, desc, category)
    tone = tone_of(text, name)
    rules = rules_of(text)
    ex = examples_of(text, rules, topic)
    lines = [
        "称呼：你",
        f"关系：{name}，在「{topic}」这件事上替你拿主意",
        f"语气：{tone}",
        f"主题：{topic}",
        f"情境：{clip(desc, MAX_DESC)}",
    ]
    if rules:
        lines.append("补充：" + "；".join(rules))
    lines.append("示例：")
    lines += [f"我：{x}" for x in ex]
    body = "\n".join(lines).strip()
    if len(body) > MAX_BODY:
        body = body[:MAX_BODY].rsplit("\n", 1)[0]
    return body


def tags_of(desc: str, category: str, name: str) -> list[str]:
    out = [category]
    for part in re.split(r"[、，,——/（）()：:；;]", desc):
        c = TOPIC_FILLER.sub("", clean(part))
        if 2 <= len(c) <= 6 and c not in out and c != name:
            out.append(c)
        if len(out) == 3:
            break
    while len(out) < 2:
        out.append(clip(name, 6) if len(out) == 1 else category)
    return out[:3]


# ---------------------------------------------------------------- 主流程

def parse_file(path: str) -> dict:
    text = open(path, encoding="utf-8").read()
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    fm = m.group(1) if m else ""

    def field(key: str) -> str:
        mm = re.search(rf"^{key}:\s*(.*)$", fm, re.M)
        return (mm.group(1) or "").strip().strip('"').strip("'") if mm else ""

    div = os.path.basename(os.path.dirname(path))
    slug = os.path.basename(path)[:-3]
    name = field("name")
    desc = field("description")
    category = DIV_NAME.get(div, "垂直专业")
    return {
        "key": f"agency.{slug}",
        "name": name,
        "emoji": field("emoji") or "🧩",
        "category": category,
        "division": div,
        "tags": tags_of(desc, category, name),
        "description": clip(desc, MAX_DESC + 20),
        "body": body_of(name, desc, category, text),
    }


def collect(src: str) -> dict:
    root = os.path.join(src, "assets", "agency-agents-zh")
    if not os.path.isdir(root):
        sys.exit(f"找不到中文专家目录：{root}")
    paths = sorted(
        os.path.join(root, d, f)
        for d in sorted(os.listdir(root))
        for f in (os.listdir(os.path.join(root, d)) if os.path.isdir(os.path.join(root, d)) else [])
        if f.endswith(".md")
    )
    experts = [parse_file(p) for p in paths]
    keys = [e["key"] for e in experts]
    if len(keys) != len(set(keys)):
        sys.exit("key 重复")
    try:
        sha = subprocess.check_output(["git", "-C", src, "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        sha = "unknown"
    digest = hashlib.sha256(
        "\n".join(f'{e["key"]}:{e["body"]}' for e in experts).encode()
    ).hexdigest()[:16]
    return {
        "version": 1,
        "source": "https://github.com/MichengAI/dsh-agency-agents",
        "sourceCommit": sha,
        "categories": LEGACY_CATEGORIES + [n for _, n in DIVISIONS if n not in LEGACY_CATEGORIES],
        "contentHash": digest,
        "experts": experts,
    }


def self_check(data: dict) -> None:
    """生成物自己的验收：写盘前先把明显不合格的挑出来，别等 Kotlin 单测去发现。"""
    bad = []
    for e in data["experts"]:
        b = e["body"]
        for key in ("称呼：", "关系：", "语气：", "主题：", "情境：", "示例：\n我："):
            if key not in b:
                bad.append((e["key"], f"缺 {key}"))
        if b.count("我：") < 2:
            bad.append((e["key"], "示例少于 2 句"))
        if len(e["tags"]) < 2:
            bad.append((e["key"], "标签少于 2 个"))
        if e["category"] not in data["categories"]:
            bad.append((e["key"], f"分类不在表里：{e['category']}"))
        if len(b) > MAX_BODY:
            bad.append((e["key"], f"正文超长 {len(b)}"))
    if bad:
        for k, why in bad[:20]:
            print(f"!! {k}: {why}", file=sys.stderr)
        sys.exit(f"{len(bad)} 条不合格")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="/tmp/dsh-agency-agents")
    ap.add_argument("--out", default="cn/app/src/main/assets/kb/experts.json")
    ap.add_argument("--check", action="store_true", help="只校验生成物是否与上游一致")
    args = ap.parse_args()

    data = collect(args.src)
    self_check(data)
    text = json.dumps(data, ensure_ascii=False, indent=1) + "\n"
    if args.check:
        cur = open(args.out, encoding="utf-8").read() if os.path.exists(args.out) else ""
        if cur != text:
            sys.exit("生成物与上游不一致，请重跑 tools/gen_experts.py")
        print(f"OK {len(data['experts'])} experts, {len(text)} bytes, hash {data['contentHash']}")
        return
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(
        f"wrote {args.out}: {len(data['experts'])} experts, {len(text)} bytes, "
        f"{len(data['categories'])} categories, hash {data['contentHash']}"
    )


if __name__ == "__main__":
    main()
