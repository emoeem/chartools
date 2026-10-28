# tools/jev — 评测脚本与公共护栏

这个目录是**评测 / 探针脚本**的家（离线跑、密钥只从环境变量读、聊天内容不进 logcat），不是 App 的一部分。App 的行为由 `app/src` 里的 Kotlin 和它的单测锁住；这里回答的是「真跑起来怎么样」。

## safeguards.py：新脚本的两个必经口

给这个目录加新脚本时，两件事不许绕过 `safeguards.py`：

- **HTTP**：凡是发请求，URL 先过 `check_http_url()`——只放行 http/https，主机名解析后逐地址拒绝私网 / 回环 / 链路本地段；显式写 IP 字面量或 `localhost` 算操作者点名，放行（本机代理是合法用法）。密钥要跟着请求走，先把目的地钉死。
- **落盘**：凡是写文件，路径先过 `safe_out()`（realpath 后必须落在仓库根内，越界直接退出而不是悄悄改写），再用 `write_text()` / `dump_json()` 一步落盘——调用点不要自己 `open(..., "w")`。

### 为什么长这样

2026-10 的安全扫描把「`--base` 直达 `urlopen`」（SSRF）和「CLI 路径直达 `open(..., "w")`」（路径穿越）在这批脚本里全部定为高危。整改后：路径侧全部被扫描器认可清零；`global/tools/or_client.py` 的同款校验（URL 是写死的常量）也被认可；但 `tools/jev/` 四处「argv → 自定义净化函数 → urlopen」仍被污点模型标红——防护是真实的（协议 + 主机名 + 解析后 IP 三层都在），只是扫描器不识别自定义函数做净化器。这 4 处按设计如此（脚本本来就是拿用户自己配的模型接口跑评测），接受残留，详见 `cn/_reports/review-findings-fixes_report.md`。

## 目录里有什么

| 文件 | 干什么 |
| :--- | :--- |
| `safeguards.py` | 公共护栏：HTTP 目的地校验 / 输出路径收敛 / 净化落盘 |
| `jev_client.py` | Jev decisions API 的最小客户端，其他脚本复用 |
| `eval_aiming.py` | 指向性评测：闸门结论 + 生产提示词的实况回归 |
| `eval_roleplay.py` | 多轮角色实况：场景一轮轮真跑，按五维打分；S1 台账 A/B 也在这 |
| `eval_kb_effect.py` | 知识库「有没有真的进到回复里」的实况 A/B |
| `build_domain_brief.py` | 整库预扫成一张领域卡 |
| `merge_kb_effect.py` | 同参数多轮 A/B 结果合并成均值表 |
| `probe_background_field.py` | 探针：Jev 线上接口对 `state.background` 字段的容忍度 |

密钥只从环境变量读（`JEV_REPLY_KEY` / `DEEPSEEK_API_KEY` / `OPENROUTER_API_KEY`），永不打印、永不落盘。
