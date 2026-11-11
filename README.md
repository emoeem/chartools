# chartools-next · 通用沟通助手（Flutter 跨平台重写）

`emoeem/chartools`（Jev 聊天助手）的跨平台重写版。技术栈 **Flutter（Dart）**，目标平台 **Android + Windows**，产品定位从「个人聊天副驾」泛化为**通用沟通助手**。

## 核心理念

一套引擎 × 多个场景模板：

```
采集（平台适配层） → 判断（意图/风险） → 起草（多候选） → 排序 → 建议面板（只建议，从不自动发送）
```

- **领域层（packages/core，纯 Dart）**：模型客户端、判断/起草流水线、人设/知识库、安全策略、场景模板——双端共享。
- **采集层（packages/capture_*，平台原生）**：
  - Android：无障碍服务 / 截屏 OCR 兜底 / 回填输入框 + 悬浮窗展示层（自旧仓库
    Kotlin 代码移植进插件；旧仓库的 Xposed 注入模块未随迁）
  - Windows：桌面「粘贴分析」入口已实现（人工粘贴 → 同一条流水线），全局热键
    （Ctrl+Alt+C 唤起，#6，纯 Dart FFI）已落地；剪贴板监听、选中文本、截图 OCR
    仍属阶段 3 计划，`capture_windows` 插件未创建
- **UI（app，Flutter）**：手机悬浮建议条（已落地）+ 桌面「粘贴分析」页（已落地；
  常驻侧边助手窗为后续形态）。

## 仓库结构

```
chartools-next/
├── app/                      # Flutter 应用（lib/：ui / application / domain）
├── packages/core/            # 纯 Dart 领域包（dart test 直接可跑）
│   ├── lib/src/jev_client/   #   模型 API 客户端（SSE 流式）
│   ├── lib/src/pipeline/     #   判断 → 起草 → 排序流水线 + 提示词模板
│   ├── lib/src/persona_kb/   #   人设 / 专家 / 知识库
│   ├── lib/src/safety/       #   安全策略
│   ├── lib/src/scenarios/    #   场景模板系统
│   └── benchmark/            #   中文对话评测样本集 + runner（用法见其 README）
├── packages/capture_android/ # Flutter 插件（Android 采集层：无障碍/OCR/悬浮窗/回填）
└── docs/                     # 架构决策、场景设计
```

Pub workspace：根目录 `pubspec.yaml` 聚合全部包，共享一个锁文件。
`capture_windows`（Windows 采集层插件，dart:ffi）属阶段 3，尚未落地——
当前 Windows 端入口是桌面「粘贴分析」页；落地后按根 `pubspec.yaml` 的
workspace 注释追加成员。

## 开发

```bash
dart pub get                    # 根目录一次拉全部（pub workspace 共享锁文件）
cd packages/core && dart test   # core 测试：纯 Dart（package:test）
cd app && flutter test          # app 测试：widget/解析用例
flutter analyze                 # 根目录可跑，覆盖整个工作区
flutter run -d windows
flutter run -d <android-device>
```

注意：测试要进成员包目录跑——工作区根包没有 `test/`，在根目录执行
`flutter test` 会报 `Test directory "test" not found.`；core 是纯 Dart 包
（不依赖 Flutter SDK），用 `dart test`。Windows 构建带插件
（shared_preferences），需要系统开发者模式提供符号链接权限：未开启时
`flutter build/run windows` 在插件阶段失败，提示打开 `ms-settings:developers`。

上游网络受限时设置镜像：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

## 场景路线

首发 5 个场景模板见 `docs/scenarios.md`，全部内置在首页（`Scenarios.builtIns`）。当前落地状态：

| 场景 | 主要平台 | 状态 |
|---|---|---|
| 个人聊天副驾 | Android | **已实现**：Android 采集页 + 悬浮窗（无障碍/OCR 快照 → 判断 → 起草 → 回填/复制）；#4 增：首次运行引导（选场景/服务商/权限三步）与服务商预设下拉（含 Ollama 本机离线档）；#5 增：低置信快照（如 OCR 兜底 + 发言人未知）不自动分析，挂起等「确认分析」；#6 增：联系人档案（「进提示词的正文」与「仅浏览信息」分区）、候选卡结构化反馈标签（可查可删）、「记住这条」确认后入库（G8）、会话检查点（重启后经「待确认恢复」提示回填） |
| 桌面粘贴分析（Windows 入口） | Windows | **已实现**：粘贴聊天记录走同一条判断/起草流水线；#4 增：候选快速改写（更短/更礼貌/换个说法）与发送前隐私预览；#5 增：与采集页同一道置信度门控（粘贴快照当前恒为高置信，闸未触发，原生采集接入后生效）；#6 增：与采集页同一套联系人档案/反馈标签/确认入库，全局热键 Ctrl+Alt+C 唤起本页并聚焦粘贴框（不读剪贴板、不自动分析）；选中文本、剪贴板监听等原生采集未接 |
| 客服/销售坐席辅助 | Windows | 模板已内置，待采集源（选中文本捕获；#6 的全局热键 Ctrl+Alt+C 目前只唤起粘贴分析页，不选词） |
| 外语学习陪练 | 双端 | 模板已内置，待采集源（剪贴板/选中文本；暂可走桌面粘贴分析） |
| 直播/社群互动助手 | Windows | 模板已内置，待采集源（弹幕/评论流粘贴） |
| 社交辅助（无障碍） | 双端 | 模板已内置；Android 采集链路与聊天副驾共享（已落地），场景模板尚未接入会话 |

场景模板的注入机制在 core（`ReplyPrompt` 的 systemAddendum/userAddendum 附加段），
但流水线上游（`ReplyClient` → `ReplyPrompt` 调用）与两个分析入口都还不传场景参数：
引导页第一步记住的场景 id（`SettingsStore.scenarioId`）目前也只有引导页在写——
当前实际请求跑的都是默认 chat_copilot（附加段为空），其余场景的采集来源未接入。

#4（P0 体验包 + 人味增强包）的其余增量两端同构：候选快速改写、「这条可以不回」
（判断 `shouldReplyNow < 0.5` 时出现）、隐私预览、「学习我的说话方式」共用同一份
`CaptureSession` 实现；服务商预设下拉与首次运行引导双端共用（引导第三步按平台
分流）；中文 AI 腔 linter 在流水线终榜后生效，命中 ≥2 条特征的候选自动改写。
落地明细见 `docs/architecture.md` 的「#4 落地记录」。

#5（外部审查借鉴 G2–G6 + 润色路由）的落地集中在信任与自动整改，判断/起草引擎
语义不变：来源不可靠的快照（置信度 ≤0.5，如 OCR 兜底叠一条发言人未知）不自动
分析，先经用户「确认分析」再发模型，两端同闸；候选的自动改写（AI 腔整改、复查
驳回重写）改走独立的润色路由，未配置时回退回复路由——候选卡上的手动精修仍走
回复路由；提示词装配堵住注入回显缝隙，不可信内容进不了 system 段、safetyBans
永远在上。适配器能力表（G2）数据与查询通道已就位、首页展示未接；中文对话
Benchmark（G5）与适配器验收表（G4）的用法见 `packages/core/benchmark/README.md`
与 `docs/architecture.md` 的「#5 落地记录」。

#6（记忆与个性化包）把 p0-plan 的 G7/G8、联系人档案简版、C9/C10 与 Windows
全局热键落地，p0-plan 的四条核心原则进了代码结构而不是提示词话术：联系人档案
的「进提示词的正文」（关系/人设/避谈词）与「仅浏览信息」在 UI 和映射两层都
分开，档案 notes 永不进提示词；反馈是六个标签的结构化计数（太正式 / 太热情 /
不够直接 / 事实对但表达不合适 / 不该承诺 / 这类先问我），可查可改可删，附言只
陈述统计事实、只进写作路（判断路与判断缓存键都看不到它）；模型猜测的事实绝不
自动入库——「记住这条」先进内存暂存区，用户在确认条上点确认才写进联系人
人设（台账当前无写入入口）；C9 用量统计（judge/reply/review/polish × 累计/本次
会话两口径）在设置页统计卡查看与重置，打点不改任何请求字节；C10 会话检查点
只存「快照签名/关系/激活联系人」，重启后经「待确认恢复上次会话」提示确认才
回填，不静默恢复；Windows 全局热键 Ctrl+Alt+C 只负责唤起（切前台 + 聚焦粘贴
框），不读剪贴板、不自动分析。落地明细见 `docs/architecture.md` 的「#6 落地
记录」。

## 与旧仓库的关系

旧仓库 `emoeem/chartools` 冻结为参考实现（`_reference/chartools`）。Kotlin 采集层移植进 `capture_android` 插件；领域逻辑以 Dart 重写进 `core`，并对照旧测试移植单测。

## 风险声明

无障碍读屏 + 回填的用法在部分聊天 App 服务条款下有封号风险；聊天文字会发送到用户自配的模型服务商。桌面端走官网分发；上架应用商店需按无障碍数据用途政策单独评估。
