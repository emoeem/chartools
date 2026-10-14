# Jev 聊天助手 · 二次开发分支

> **这是基于 Jev 聊天助手二次开发的本地分支**（包名 `com.jev.probe`，当前版本 v1.8）：**不是上游仓库，也不是原作者的发布**，只在本机构建使用，没有发布自己的安装包。上游项目：[jev-chat/jev-chat-jarvis](https://github.com/jev-chat/jev-chat-jarvis)。按 [NOTICE](NOTICE) 注明出处；不使用上游名称或官网域名暗示由原作者出品或背书。

仓库结构与上游一致：

| 目录 | 内容 |
|---|---|
| [`cn/`](cn/) | **国内版（Android）——本分支的全部开发在这里**：[说明与构建](cn/README.md) · [更新日志](cn/CHANGELOG.md) · [工程约定](cn/CLAUDE.md) |
| [`global/`](global/) | 海外版（WhatsApp，英文），上游维护 |
| [`.github/`](.github/) | 仓库总览 README：[简体中文](.github/README.zh-CN.md) · [English](.github/README.md) · [Tiếng Việt](.github/README.vi.md) |

本分支相对上游 v1.7 的改动（采集层 Telegram / TIM / 微信适配、本机文档导入、技能包、LSPosed 可选注入层、记忆与上下文修复、界面重组等）见 [`cn/CHANGELOG.md`](cn/CHANGELOG.md) 的「未发布」各节；国内版功能详情见 [`cn/README.md`](cn/README.md)。
