# 人设生效的两处缺口：联系人覆盖的说实话 + 缓存键上锁

日期：2026-10-27 · 范围：`core/kb/StyleSource.kt`、`jev/ReplyCacheKey.kt`、`ExpertActivity`、`KnowledgeActivity`

## 一、根因（带证据）

### 1.1 联系人专用人设静默覆盖专家正文

`ReplyClient` 里两处同款：

```kotlin
// 第 316 行 draftAsk、第 221 行 review
val rawStyle = ctx?.contact?.persona?.trim().takeUnless { it.isNullOrBlank() } ?: style
```

优先级本身是产品的、有理由的。问题在**没人告诉用户**：他在专家库点了「用」，toast 弹「已套用」，只要这个聊天写过专用人设，提示词一个字节都不变。这跟「点了没反应」是同一件事。

顺带一个隐患：同一个判定写了两遍。两处一旦漂，复查就会拿着一张和起草不同的人设卡去判第 3、5 条标准（「有没有和已知的称呼/边界冲突」）——而这种错误不会报错，只会让复查的结论莫名其妙。

### 1.2 缓存键没有测试

`JevClient.cacheKey` 十个分量，含 `prefs.style`。它藏在私有方法里、直接读 `Prefs`，单元测试够不着，所以「换专家后必须重打」这件事**没有任何断言**。三个月后谁加个新维度、顺手删掉一个分量，表现是「改了输入、回复没变」——不报错，无日志。

### 1.3 `avoid` 的键有真实碰撞

`avoid.joinToString("\u001f")`：`emptyList()` 与 `listOf("")` 拼出来都是 `""`，`listOf("a\u001fb")` 与 `listOf("a","b")` 也一样。撞了就是命中一条本不该命中的候选，表现仍是「回复没变」。

## 二、改了什么

| 文件 | 改动 |
|---|---|
| `app/src/main/java/com/jev/probe/core/kb/StyleSource.kt` | 新增。`resolve(expert, contactPersona)` 返回 `text / from / shadowedExpert`，成为「哪段正文进提示词」的唯一判定处。**专家正文原样透传不 trim**（只有联系人那句 trim，与改造前逐字等价） |
| `app/src/main/java/com/jev/probe/jev/ReplyClient.kt` | 两处 `?: style` 改调 `StyleSource.resolve(...).text`，行为字节级不变 |
| `app/src/main/java/com/jev/probe/ExpertActivity.kt` | 套用成功后数一下「写了专用人设的联系人」，>0 就追加一句：`3 个联系人写了专用人设，那里会盖过它`。只数不读文本 |
| `app/src/main/java/com/jev/probe/KnowledgeActivity.kt` | 人设字段下方一行：`填了这里，专家库套用的正文对这个人就不生效了` |
| `app/src/main/java/com/jev/probe/jev/ReplyCacheKey.kt` | 新增。`reply(...)` / `judge(...)` 纯函数；`avoid` 改成逐条长度前缀 |
| `app/src/main/java/com/jev/probe/jev/JevClient.kt` | `cacheKey` / `judgeKey` 反过来调纯函数，其余不动 |
| `app/src/test/java/com/jev/probe/core/kb/StyleSourceTest.kt` | 新增 9 例，含与改造前表达式的**逐字等价**对照 |
| `app/src/test/java/com/jev/probe/jev/ReplyCacheKeyTest.kt` | 新增 7 例，十个分量逐个变异 |

## 三、验收（真实输出）

### 3.1 单测

```
$ ./gradlew :app:testDebugUnitTest --offline --rerun-tasks
> Task :app:testDebugUnitTest
BUILD SUCCESSFUL in 28s
26 actionable tasks: 26 executed

suites=85 tests=1035 failures=0 errors=0 skipped=2
```

上一轮基线 83 / 1019 / 0 / 0 / 2。本轮 +2 suites / +16 tests（9 + 7），失败 0。

中途出现过一次红：

```
ReplyCacheKeyTest :: avoid 多条与单条不同
java.lang.AssertionError: Values should be different. Actual: S?R?ST?M?3??C?L?J?AUTO
```

不是测试写错，是 `emptyList()` 与 `listOf("")` 真的同键（见 1.3）。修的是键的编码（长度前缀），不是放宽断言。

### 3.2 行为不变的部分

- `styleBlock` / 提示词字节：`StyleSourceTest.text 与改造前那行代码逐字等价` 用 `legacy()` 对照了 15 组输入（空串 / 纯空白 / 前后空格 / 多行 / 含分隔符）。
- 331 位专家的端到端断言（`ExpertApplyEndToEndTest`）未改一行，仍在 1035 里全绿。

## 四、自验缺口

1. **界面提示没有真机取证**。toast 文案与联系人字段旁那行字，只做了编译与单测层面的验证（`shadowingContacts()` 走 `runCatching`，读盘失败退 0），**没有在设备上看过实际渲染**。
2. **`shadowingContacts()` 的计数没有单测**。它依赖 `KbStore`（要 `Context`），当前测试栈没有 Robolectric，所以只测了纯函数部分。
3. **`StyleSourceTest` 的等价性只覆盖 `String` 语义**。`ctx?.contact?.persona` 的 null 语义（`ctx` 为 null / `contact` 为 null）没有被单独构造出来测，靠的是「都归一到 `null` 参数」这一层。
4. **加锁防的是退化，不防起点错**。如果某个输入从一开始就不在键里，这一组测试只会把一个错的行为锁住。
5. 未跑真机、未 commit 之后的 push（按 `cn/CLAUDE.md` 第 8 条，提交与推送由人拍板）。
