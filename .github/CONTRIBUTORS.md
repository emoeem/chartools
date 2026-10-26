# 贡献者

本仓库是 [Jev 聊天助手](https://github.com/jev-chat/jev-chat-jarvis) 的**二次开发本地分支**（包名 `com.jev.probe`），与上游三端项目分别维护。这份名单分两节：先说清本分支谁在维护，再按 [NOTICE](../NOTICE) 的要求保留上游贡献者署名。

## 本分支（`com.jev.probe` 二次开发）

| 谁 | 做什么 |
|---|---|
| [@emoeem](https://github.com/emoeem) | 本分支全部开发与维护：Telegram / TIM / 微信 OCR 采集、知识库与技能、人设库、台账与复查、先判后写与回复自然度、root 自动修复、真机验收（OPPO PJE110 / 小米 14） |
| [@zhonglei451-cmyk](https://github.com/zhonglei451-cmyk) | global 版中文文档（PR #1） |

本分支相对上游的完整改动清单见[更新日志](../cn/CHANGELOG.md)；功能总览见[功能介绍](../cn/docs/feature-guide.md)。分支不单独发版、不设外部贡献流程；上游作者未参与这些改动，也不为其背书。

## 上游项目与贡献者（署名保留，按 NOTICE 要求）

上游是一个三端并行的开源项目，只读屏幕、不注入、不 hook、不替你发送。

### 上游三端支持范围

| 平台 | 当前覆盖 |
|---|---|
| Android | QQ、X / Twitter 私信支持全链路，飞书支持 OCR 兜底，WhatsApp 一对一聊天（测试中）；其它未适配 App 支持手动「截屏识别一次」 |
| macOS | 桌面聊天窗口，看屏 + 本地小模型 |
| Windows | 桌面聊天窗口，窗口截图 + 离线 OCR |

三端共用同一套判断内核，差异在采集方式：Android 走无障碍节点加离线 OCR，macOS 与 Windows 走屏幕录制加 OCR。本分支 Android 的支持范围（含 Telegram、TIM、微信 OCR、WhatsApp）见[项目总览](README.md#平台支持)。

### 维护者与分工

| 平台 | 仓库 | 主要维护者 |
|---|---|---|
| Android（主入口） | [jev-chat-jarvis](https://github.com/jev-chat/jev-chat-jarvis) | [@Finderchangchang](https://github.com/Finderchangchang) |
| macOS | [jev-chat-jarvis-mac](https://github.com/jev-chat/jev-chat-jarvis-mac) | [@eatmoreduck](https://github.com/eatmoreduck) |
| Windows | [jev-chat-windows](https://github.com/jev-chat/jev-chat-windows) | [@rezoch340](https://github.com/rezoch340) |
| 三端测试 | 全部仓库 | [@HeiGeAi](https://github.com/HeiGeAi) |
| 组织与项目管理 | [jev-chat](https://github.com/jev-chat) | [@Finderchangchang](https://github.com/Finderchangchang) |
| 官网与组织页 | [jev-chat.github.io](https://github.com/jev-chat/jev-chat.github.io) | [@Finderchangchang](https://github.com/Finderchangchang) |

### 上游贡献者

**测试**：[@HeiGeAi](https://github.com/HeiGeAi)（三端真机验证与问题复现）

**Android**：[@Finderchangchang](https://github.com/Finderchangchang)、[@smgonthebeat](https://github.com/smgonthebeat)（WhatsApp 读取规则与录屏数据，#73）、[@ahxoeh](https://github.com/ahxoeh)（面板稳定性与截屏识别加固，#71）、[@xuancanhit99](https://github.com/xuancanhit99)（回复与视觉请求兼容更多网关，#74）

**macOS**：[@eatmoreduck](https://github.com/eatmoreduck)、[@shanyazhou](https://github.com/shanyazhou)、[@baishatan](https://github.com/baishatan)、[@xixikaixin](https://github.com/xixikaixin)、[@liubai00](https://github.com/liubai00)

**Windows**：[@rezoch340](https://github.com/rezoch340)

## 项目红线（上游与本分支同守）

1. **纯只读**。不注入目标 App、不 hook、不解密数据。
2. **发送永远手动**。程序不替你按发送键，填入只是把候选放进输入框。
3. **只处理你自己有权查看的聊天**。

想给**上游**贡献：流程、认领规则与自测要求见 macOS 仓库的 [CONTRIBUTING.md](https://github.com/jev-chat/jev-chat-jarvis-mac/blob/master/CONTRIBUTING.md)。本分支为本地开发，不设外部贡献流程。

## 许可证

代码以 MIT 协议开源。使用名称或域名时不得暗示由原作者出品或背书，详见仓库根目录的 [NOTICE](../NOTICE)。
