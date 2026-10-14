<div align="center">

<img src="assets/images/logo.png" width="150" alt="Jev 聊天助手" />

# Jev 聊天助手 · 二次开发分支

**Jev 对话副驾：在支持的平台分析聊天并给出回复建议；各端功能见对应项目说明，发送由你决定。**

> **这是基于 Jev 聊天助手二次开发的本地分支**（包名 `com.jev.probe`，当前版本 v1.8）：**不是上游仓库，也不是原作者的发布**，只在本机构建使用，没有发布自己的安装包。上游项目：[jev-chat/jev-chat-jarvis](https://github.com/jev-chat/jev-chat-jarvis)。按 [NOTICE](../NOTICE) 注明出处；不使用上游名称或官网域名暗示由原作者出品或背书。

[![Version](https://img.shields.io/badge/%E7%89%88%E6%9C%AC-v1.8-1f6feb?style=flat-square)](../cn/CHANGELOG.md)
[![License](https://img.shields.io/badge/license-MIT-1f6feb?style=flat-square)](../LICENSE)

[上游官网](https://chatjevs.com) · [上游安装与设置指南](https://chatjevs.com/guides/android-setup.html) · [上游候选回复使用建议](https://chatjevs.com/guides/review-ai-replies.html) · [隐私政策](../cn/PRIVACY.md) · [更新日志](../cn/CHANGELOG.md)

**简体中文** · [English](README.en.md) · [Tiếng Việt](README.vi.md)

</div>

## 本分支相对上游的改动

本分支在上游 v1.7 之上继续开发，全部改动都在本仓库，完整清单见[更新日志](../cn/CHANGELOG.md)的「未发布」各节：

- **采集层**：新增 Telegram、TIM 适配器；微信走「截屏 + 本机 OCR」只读路径（按气泡颜色判左右）；OCR 分组、说话人归属、近期回复去重。
- **知识库**：本机文档导入（PDF / Word / EPUB / 网页，扫描件回落本机 OCR）、技能包（Agent Skills，按对话自动命中）、联系人档案与台账。
- **可选注入层**：基于 LSPosed / Vector 的只读增强，默认关闭、逐 App 显式开启，读不到立即回落无障碍路径并在 Trace 标明原因。
- **上下文与记忆**：写作上下文窗口 10 → 20 条；知识库命中门槛修正（单个技能包此前在数学上不可达）；记忆未激活时卡片直接提示。
- **界面**：悬浮卡贴边胶囊、候选与判断分级（详情可折叠）、设置页分组、推进档位（自动 / 收着 / 自然 / 加码）。
- **接口与生成**：判断接口新增 DeepSeek 预设（自动切「OpenAI 聊天模式」）、重复惩罚参数、人设卡黄灯键。

上游作者未参与这些改动，也不为其背书；上游原版功能与文档见[上游仓库](https://github.com/jev-chat/jev-chat-jarvis)。


## 开始使用 Jev

| Android（本分支） | 上游 Windows | 上游 macOS |
| :---: | :---: | :---: |
| 从源码构建，见下方[快速开始](#快速开始) | [上游 Windows 版](https://github.com/jev-chat/jev-chat-windows/releases) | [上游 macOS 版](https://github.com/jev-chat/jev-chat-jarvis-mac/releases) |
| Android 11+ · ARM64 · 包名 `com.jev.probe` | Windows 10 1903+ / 11 | macOS 13+ · Apple Silicon |

本分支没有自己的发布页；想装原版上游应用，请去[上游仓库](https://github.com/jev-chat/jev-chat-jarvis)，那是另一个包名的应用，和这里的构建不是同一个安装包。

**安装教程 · 交流更新：**[Android 安装说明](#快速开始) · [上游 Windows 项目说明](https://github.com/jev-chat/jev-chat-windows#使用说明) · [上游 macOS 项目说明](https://github.com/jev-chat/jev-chat-jarvis-mac#用法)。

## 为什么用它

- **它先判断，再写字。** 大多数工具直接让模型编一句回复。Jev 先用判断模型给出对方真实意图、危险等级、该不该马上回，再据此起草回复。
- **不动你的聊天软件。** 不 hook、不改包、不走任何 App 的接口或账号、不读数据库，只用系统无障碍服务读「屏幕上正在显示的对话」。
- **发送权永远在你手里。** 程序只把回复填进输入框，从不自动发送，不碰转账 / 红包 / 收款。
- **一套内核，多平台。** QQ、TIM、Telegram、微信、X 真机跑通，飞书靠 OCR 补正文，WhatsApp 按录屏数据验证。新增一个 App 只需写一个几十行的适配器；目标 App 不给无障碍树时（微信就是），退到「截屏 + 本机 OCR」这条路。
- **它认识你的人和事。** 本地知识库与联系人档案，分析时自动带上命中的笔记和这个人的历史，回复不会和你的设定打架。知识库可以直接吃 **PDF / Word(.docx) / EPUB / 网页**：有文字层的 PDF 直接抽，扫描件自动退回本机 OCR，也可以只粘贴一个网址把正文抓成本机笔记。
- **技能（Agent Skills）。** 按 Anthropic 的 Agent Skills 规范把说明文档做成技能包（`SKILL.md` + 附件），导入后按对话内容自动命中，命中的说明会进回复提示词——相当于给助手装一门手艺。全部在本机，导入的技能默认关闭，要你在列表里点头才生效。
- **接口自己配。** 判断 / 回复 / 视觉三路分别可填。分析时，聊天文字和你启用的背景信息会发给你配置的模型服务商；作者不运营中转服务器。
- **本机存储可控。** 密钥、知识库和可选历史存 App 私有空间；截图只在本机 OCR，不上传。第三方服务商如何处理收到的内容，以其隐私政策为准。

## 平台支持

| 平台 | 状态 | 采集方式 | 备注 |
|---|---|---|---|
| QQ Android | ✅ 全链路 | 无障碍读节点 | 9.3.50 实测（群聊）；1v1 按同结构推断 |
| TIM（`com.tencent.tim`） | 🧪 待验正文解析 | 无障碍读节点 | 4.1.0（versionCode 4050）真机采样定规。TIM 的 viewId 被 AndResGuard 混淆：正文 `9u`、气泡 `n9e`、昵称 `9w`、输入框 `input`，升级版本可能失效；分边按「气泡贴边」（左边缘≈屏宽 13% = 对方，右边缘≈屏宽−5px = 自己）；群聊标题常取不到（标题栏只渲染 emoji + 人数） |
| X / Twitter 私信 | ✅ 全链路 | 解析 Compose 节点的 content-desc | 12.25 实测，中文界面；英文界面未验 |
| 飞书 / Lark | ✅ OCR 兜底（真机验证） | 无障碍读气泡矩形 + ML Kit 离线 OCR 识别正文 | 正文自绘不在无障碍树里，1.3 起对每个气泡矩形做 OCR；我/对方按已读状态判 |
| WhatsApp | 🧪 一对一聊天 | 无障碍读节点 | 只读一对一聊天，群聊不读，不截屏；对方说英文时候选回复用英文；读取规则来自 [@smgonthebeat](https://github.com/smgonthebeat)（#73），按 WhatsApp 2.26.38.73 录屏数据验证 |
| Telegram | ✅ 全链路 | 无障碍读节点 | 12.10.1（versionCode 70382）真机验证：行文本自带「昵称 / 正文 / 状态行」，我或对方按状态行动词判（`已发送`＝我、`已收到`＝对方），所以**界面语言不是中文或英文时判不出左右**；聊天页靠底部输入框（y ≥ 0.6 屏高）判定，聊天列表页与话题页不出卡片 |
| 微信 | ✅ 全链路（OCR） | 截屏 + 本机 OCR | 8.0.78 实测：微信**不给第三方无障碍树**（整棵树只有一个 `bounds="[0,0][0,0]"` 的空节点，关掉系统里所有无障碍服务后仍然如此），所以只能读屏。做法是截屏 → 按气泡填充色分左右（绿色＝自己，灰色＝对方；自己发的图片/文件卡片是灰的，用右侧头像重叠兜底）→ ML Kit 中文 OCR；只读深色主题实测，换皮肤/背景未验 |
| 其它未适配 App | ✅ 手动 | 悬浮窗菜单「截屏识别一次」整屏 OCR | 不自动、不分我/对方（全部当作对方所说并在面板标注）；隐藏界面内容或禁止截屏的 App 不支持 |
| macOS / Windows（独立项目） | ✅ 已提供 | 见各自仓库说明 | [macOS 版](https://github.com/jev-chat/jev-chat-jarvis-mac) · [Windows 版](https://github.com/jev-chat/jev-chat-windows) |
| 网页 | ⏳ 规划 | — | 尚无网页版 |

本项目只读你自己设备上、你自己有权查看且当前版本支持的聊天；隐藏界面内容或禁止截屏的 App 一律不读。微信属于前者（不暴露无障碍树），所以对它只能用系统截屏 + 本机 OCR 这条只读路径，截图不出设备。

> **使用风险**：在 QQ、TIM、Telegram、微信、飞书、X、WhatsApp 等第三方 App 里使用本助手，可能不符合该 App 的用户协议，账号有被限制或封禁的风险，请自行判断是否使用。

## 快速开始

**1. 构建。** 本分支没有发布安装包，从源码构建一份 debug 包（Android 11+，仅支持 ARM64 / `arm64-v8a`）：

```bash
# 需要 JDK 17 或 21，以及 Android SDK（compileSdk 35）
cd cn
JAVA_HOME=/usr/lib/jvm/java-21-openjdk bash gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

原版上游的 release 包在上游仓库的 [Releases](https://github.com/jev-chat/jev-chat-jarvis/releases)，那是包名不同的另一个应用（上游 `jev-assistant-v1.7-release.apk`），和这里的构建互不覆盖，也不能就地升级。

**2. 填密钥。** 打开 App → 设置 →「接口」分三张卡：判断接口 / 回复接口 / 视觉接口。最简单只填「判断接口」一栏的 [OpenRouter](https://openrouter.ai/) API Key，其余两栏留空会自动继承这把密钥就能用。不想用 OpenRouter 也行：判断接口里有「DeepSeek 官方」预设，填一把 DeepSeek 的 Key 就能直接当判断接口用（DeepSeek 没有 Jev 判断模型，它会改用「OpenAI 聊天模式」按同一套题作答，见下文）。想换回复模型（默认 `deepseek/deepseek-chat-v3.1`，国内 Gemini / OpenAI 会被区域限制）就在「回复接口」选预设（OpenRouter / DeepSeek 官方 / 通义兼容）或自填地址，每张卡都有独立的一键连通测试。

**3. 开权限。** 按主页向导开三项：

- 无障碍（读取当前支持的聊天界面；升级到 1.3+ 后需要把无障碍关掉再打开一次，截屏能力才生效）
- 悬浮窗 / 显示在其他应用上层（展示分析）
- 自启动 + 省电无限制（小米 / HyperOS 必做，否则后台被冻结读不到消息）

装过 debug 包的要先卸载再装 release（签名不同），卸载会清掉密钥和设置。小米 / HyperOS 重装后悬浮窗权限会被重置，装完按向导再开一次。

## 功能

### 判断与候选回复

- 判断模型一次给出：对方真实意图、危险等级（1–9）、对方要什么、该不该马上回、最佳动作。约 1 秒，带把握度。
- 生成模型起草 3 条口语化候选，判断模型按「最合适」排序并给出占比。
- 悬浮窗里点一下复制或填入，填入用 `ACTION_SET_TEXT`，失败自动退到剪贴板粘贴，**任何情况下都不发送**。

### 知识库与联系人

在设置 → 分析 →「知识库与联系人」。

- **笔记**：标题 / 内容 / 标签 / 常驻。常驻笔记每次都带；其它笔记要标签或标题出现在会话标题或最近 6 条消息里才带，最多 5 条。支持多行文本粘贴导入，空行分段，每段首行当标题。
- **联系人**：姓名 / 别名（每行一个）/ 关系 / 备注。会话标题匹配姓名或任一别名时生效，自动忽略群名尾部人数、首尾空白和大小写差异。悬浮窗气泡长按可把当前会话一键存为联系人。
- **历史**：「记录聊天历史（只存本机）」默认关闭；开启后每次分析带上最近 N 条（默认 30），并自动去掉屏幕上已经显示过的部分。
- **清除**：知识库与历史都存在 App 私有目录，设置里「清空知识库与历史」一键删除，不进日志、不进 git。具体数据类别、用途、接收方和保留方式见[隐私政策](../cn/PRIVACY.md)。
- 悬浮窗面板顶部会显示一行「知识库 N 条 · 历史 M 条」，方便确认到底带了什么。

### 接口与模型

- 判断 / 回复 / 视觉三路的地址、密钥、模型分别可填。
- 判断接口新增内置预设「博查 Jev」，排在选项第二（OpenRouter / 博查 Jev / TypeSafe 直连 / Vercel / OpenCode Zen / 自定义），选中后自动填好服务地址 `https://jev.bocha.cn` 与模型 `bocha-jev-v1`（协议与 TypeSafe 一致），页面上会显示官方地址并支持一键复制，当前限时免费。全新安装默认使用 OpenRouter；已经配置过判断接口的老用户不受影响，provider 和密钥都不会被改动。
- 判断接口另有「Vercel」预设：地址 `https://ai-gateway.vercel.sh/typesafe`，模型 `typesafe-ai/jev`，密钥用 [Vercel AI Gateway](https://vercel.com/ai-gateway/models/jev) 的 key。协议与 TypeSafe 直连相同（`POST /v1/systemone`）。
- 判断接口另有「OpenCode Zen」预设：地址 `https://opencode.ai/zen`，模型 `jev-1.13`（输出免费、输入 $0.042/M，一次判断约 1000 输入 token），密钥用 [OpenCode Zen](https://opencode.ai/zen) 的 key。协议与 TypeSafe 直连相同（`POST /v1/systemone`）；想全免费可手动改成 `jev-1.13-free`（限时，功能受限）。
- 判断接口也可以用 DeepSeek：内置「DeepSeek 官方」预设（地址 `https://api.deepseek.com/v1`，模型 `deepseek-chat`，填 DeepSeek 的 Key）。DeepSeek 不提供 Jev 判断模型，所以选中它会自动把判断协议切成「OpenAI 聊天模式」：把同一套 7 道题写成提示词发给聊天模型，让它按同样的 JSON 结构作答，意图、危险等级、对方要什么、该不该马上回、候选排序全都照常工作。
- 判断接口新增「Jev 判断协议 / OpenAI 聊天模式」两枚药丸，决定这一路怎么说话。Jev 判断协议＝把题发给 Jev 判断模型（TypeSafe 系，答案经过校准）；OpenAI 聊天模式＝发给普通聊天模型（如 DeepSeek），概率和危险等级由它自己估计，不如 Jev 准，而且一次判断要带上整套题目（约 2000–3000 输入 token，比 Jev 慢也贵）。预设会自动选好对应协议（DeepSeek 官方＝聊天模式，其余＝Jev 协议），自定义地址可以自己选；老配置升级后协议为空，按 provider 推断，路由不变。
- 内置 OpenRouter、博查 Jev、TypeSafe 直连、Vercel、OpenCode Zen、DeepSeek 官方、通义兼容预设，每张卡一键连通测试。
- 只有一把密钥也能用：回复、视觉留空自动继承判断接口的配置。
- 从旧版本升级时，原来那把密钥会一次性迁移到新的三卡结构。

### 采集与 OCR

- 一个 App 一个适配器，服务按前台包名分发，适配器只负责把当前窗口变成「标题 + 消息列表」。
- 无障碍树里没有正文时，对支持的聊天 App 自动截屏并用 ML Kit 中文离线模型识别，不上传图片、不需要 Google 服务。
- 截屏有限频和失败退避，不会每秒连拍；识别时会躲开自己的悬浮窗。
- 未适配的 App 可在悬浮窗菜单里手动触发「截屏识别一次」。

## 常见问题

<details>
<summary><b>它会替我发消息吗？</b></summary>

不会。程序只把选中的回复填进输入框，发送键永远由你自己点。转账、红包、收款一律不碰。

</details>

<details>
<summary><b>需要 root 或 Xposed 吗？会不会封号？</b></summary>

不需要 root，也不用装任何模块。它不修改聊天软件的安装包、不注入进程、不调用对方 App 的接口或账号体系，只读系统无障碍服务暴露出来的界面内容，和读屏软件的工作方式一样。

</details>

<details>
<summary><b>我的聊天记录会被上传吗？</b></summary>

触发分析时，当前聊天文字以及你启用的联系人备注、知识库命中内容和历史记录会发送到你在设置里配置的模型接口。项目作者不运营中转服务器，也不会收到这些内容；截图在本机 OCR，不会上传。历史记录默认关闭，开启后仅保存在手机 App 私有目录。第三方模型服务商可能按自己的政策处理请求内容，请在使用前查看[隐私政策](../cn/PRIVACY.md)及所选服务商的政策。

</details>

<details>
<summary><b>悬浮球不见了，或者读不到消息怎么办？</b></summary>

多半是国产 ROM 把后台进程冻结了。先确认无障碍、悬浮窗、自启动、省电无限制四项都开着，小米 / HyperOS 尤其要开后两项。重装后悬浮窗权限会被重置，按主页向导再开一次。在聊天界面里随便点一下通常能自愈。

</details>

<details>
<summary><b>飞书里读不到正文？其它 App 能用吗？</b></summary>

飞书的消息正文是自绘控件，无障碍树里没有文字，1.3 起改为对每个气泡矩形做离线 OCR。其它未适配的 App，可以在悬浮窗菜单里点「截屏识别一次」，整屏 OCR 后同样能分析，只是不区分我方和对方。

</details>

<details>
<summary><b>要花钱吗？</b></summary>

软件本身免费开源。模型调用走你自己的 API Key，按用量在对应服务商那边结算，项目不经手任何费用。

</details>

<details>
<summary><b>升级之后没反应？</b></summary>

把系统设置里的无障碍开关关掉再打开一次。1.3 起新增了截屏能力，服务需要重新绑定才会生效。

</details>

## 它怎么工作

![Jev Android 对话副驾关键流程：本机读取与 OCR、发送文字到用户配置的模型接口、展示候选并由用户决定是否发送](assets/android-core-flow-illustrations/01-chat-copilot-flow.png)

图中展示数据边界：聊天界面读取与 OCR 在本机完成；触发分析后，文字和启用的背景信息发送到你配置的模型服务商；候选回复由你确认，应用不会代发。详见[隐私政策](../cn/PRIVACY.md)。

- **采集**：一个 App 一个适配器，服务按前台包名分发。适配器只负责把当前窗口变成「标题 + 消息列表（谁说的、说了什么）」，下游全部通用；树里没有正文时走截屏 + 离线 OCR 兜底（限频、失败退避，不会每秒连拍）。
- **判断**：[Jev](https://docs.typesafe.ai/) 只回答选择 / 打分 / 是非，一次请求发全部题目，约 1 秒返回；命中知识库时 state 里会带 `background`（关系 + 联系人备注 + 命中笔记）和 `history`（历史消息）。
- **回复**：生成模型起草 3 条候选，Jev 排序；提示词要求回复必须与知识库一致，不编造知识库没有的事实。
- **回填**：`ACTION_SET_TEXT`，失败则剪贴板 + `ACTION_PASTE`，不发送。

<details>
<summary><b>适配一个新的聊天 App</b></summary>

1. 在 `capture/ChatAppAdapter.kt` 实现 `ChatAppAdapter`：`pkg` 是包名，`extract(root, res)` 从无障碍树取出标题和消息列表（`Msg(side, text)`，`side` 为 `me` / `other`），不在聊天窗时返回 `null`。
2. 在 `capture/ChatCaptureService.kt` 的 `adapters` 加一行。
3. 判断、候选、悬浮窗、填入都不用动。

先用 `adb shell uiautomator dump` 看目标 App 暴露了什么，已有四个专用适配器，另有未适配 App 的手动 OCR 入口：

| App | 树的情况 | 适配器怎么做 |
|---|---|---|
| QQ | 节点开放，有 id | 正文 `id/mjn`、标题 `id/371`，按气泡贴哪侧头像判谁说的 |
| X | Compose，无 id，text 为空 | 解析 content-desc `发件人：正文。时间。Read`，发件人是「你」即我方 |
| 飞书 | 正文自绘，树里没有文字 | 树上拿 bubble_content_container 矩形与已读状态，OCR 每个矩形的正文 |

适配器返回 `null` 表示不在聊天窗，返回空消息列表表示在聊天窗但树里没正文——只有后者会触发 OCR 兜底。

QQ、X 全程只有一个 Activity，判「是不是聊天窗」要看树里有没有该有的节点（如输入框），不能看 Activity 名。

</details>

<details>
<summary><b>构建与目录结构</b></summary>

JDK 17 + Android SDK（platform 35 / build-tools 35）。

```bash
cd cn
./gradlew assembleDebug      # app/build/outputs/apk/debug/app-debug.apk
./gradlew assembleRelease    # 需要仓库外的签名 properties，路径由 JEV_KEYSTORE_PROPS 指定
```

- `cn/app/` — Android 应用（Kotlin，传统 View）
  - `capture/` 无障碍采集：`ChatAppAdapter.kt` 各 App 适配器、`ChatCaptureService.kt` 分发服务、前台保活、`ocr/` 截屏与离线识别
  - `jev/` Jev 客户端与题目集 · `overlay/` 悬浮窗 · `core/` 配置与数据模型（含 `core/kb/` 知识库存储与上下文构建）
  - `KnowledgeActivity` 知识库管理页（笔记 / 联系人）
- `cn/tools/jev/` — Jev 题目集与校准脚手架（Python）
- `cn/docs/` — 设计与验收文档
- `cn/apk/` — 签好名的 release 包

</details>

## 已知限制

- **国产 ROM 后台冻结**：小米 / HyperOS 会杀后台进程，前台保活、自启动、省电无限制都配了仍可能被杀，气泡短暂消失，在聊天里再交互一下自愈。
- **飞书正文靠 OCR**：飞书正文是自绘控件，无障碍树里只有气泡矩形，1.3 起对每个矩形做离线 OCR；我 / 对方按已读状态判断，判反时请用「存为联系人」并在备注里说明，或关掉自动分析改手动。
- **X 只按中文界面验过**：分隔符 `：`、`上午 / 下午`、`Read` 是中文界面实测；英文界面只做了兜底，未验。
- **群聊**：按一对一分析，「对方」与关系设定对群聊不准。
- **中文**：Jev 主训练语言是英文，题目用英文、聊天内容保留中文；建议用自己的真实对话做一批标注校准（见 `cn/tools/jev/`）。
- **知识库检索是标签/标题包含匹配**，不做语义检索，笔记请打好标签才能被命中。历史按「谁说 + 原文」去重，同一个人重复说同一句只记一次。
- **OCR 依赖系统放行截屏**：无障碍服务要被系统允许截屏才能用，小米 / HyperOS 可能拒绝（面板会提示失败原因）；受保护窗口（`FLAG_SECURE`）截不到。
- **OCR 只认屏幕上看得见的部分**：长消息被截断的部分读不到；识别有错字。
- **包体变大**：ML Kit 中文离线模型让 APK 从约 12 MB 增至约 27 MB，且只打 arm64-v8a。
- **不支持隐藏界面内容或禁止截屏的 App**：这类 App 里不读取、不截屏、不填入。

## 版权与许可

上游项目 Copyright © 2026 Finderchangchang 与 jev-chat 贡献者，代码以 [MIT](../LICENSE) 协议开源，另见 [NOTICE](../NOTICE)。**本仓库是上游的二次开发分支（本地使用，包名 `com.jev.probe`，版本 v1.8），上游作者未参与、也未背书本分支的任何改动。**

- **可以商用**：个人和公司都可以使用、修改、再分发，或集成进自己的产品，不需要付费或事先授权。
- **必须注明出处**：分发或商用时保留 LICENSE 与 NOTICE，并在产品「关于」页、说明文档或发布页写明来源。推荐写法：`基于 Jev 聊天助手（https://github.com/jev-chat/jev-chat-jarvis）二次开发`。
- 不要用「Jev 聊天助手」「jev-chat」名称或 chatjevs.com 域名暗示由原作者出品或背书。

**隐私与免责声明**：触发分析时，聊天文字和启用的背景信息会发送到你自行配置的第三方模型服务商；截图仅在本机 OCR。请阅读[隐私政策](../cn/PRIVACY.md)以及所选服务商的政策，并遵守 QQ、TIM、Telegram、微信、X、飞书、WhatsApp 等软件的用户协议与当地法律法规；因违反第三方 App 用户协议导致的账号限制等后果由使用者自行承担。作者不对第三方服务商的数据处理行为或使用后果负责。

