# 场景模板设计

「一套引擎 × 多个场景」是 chartools-next 相对旧仓库的核心泛化：把「聊天副驾」的判断→起草→排序引擎，通过可插拔的提示词模板服务到多个场景。

## 模板结构

```dart
class ScenarioTemplate {
  final String id;          // 蛇形命名，如 chat_copilot
  final String name;        // 界面显示名
  final String description; // 一句话说明
  final List<String> platforms; // android / windows
  final String systemAddendum;  // 追加在 system prompt 末尾
  final String userAddendum;    // 插在 user prompt 最后一句之前
}
```

**兼容锁**：`chat_copilot`（个人聊天副驾）的两个附加段为空串——选它（或不选场景）时，提示词与没有场景功能之前**逐字节一致**，由单测钉住。

## 首发场景

| id | 名称 | 平台 | 采集来源 | 要解决的问题 |
|---|---|---|---|---|
| `chat_copilot` | 个人聊天副驾 | Android | 无障碍/OCR（阶段 2 移植） | 现有能力，保持 |
| `support_agent` | 客服/销售坐席辅助 | Windows | 热键 + 选中文本（阶段 3） | 读网页客服工作台的对话，知识库检索注入，回复贴合产品口径与合规避谈词 |
| `language_learning` | 外语学习陪练 | 双端 | 剪贴板/选中文本 | 翻译 + 语气纠正 + 地道表达建议；候选分「直译/地道/进阶」三档 |
| `live_interaction` | 直播/社群互动助手 | Windows | 弹幕/评论流粘贴 | 高频短回复，语气贴合主播人设，避免复读过弹幕 |
| `social_a11y` | 社交辅助（无障碍） | 双端 | 同聊天副驾 | 面向社交焦虑/听障人群：温和措辞、明确社交预期、降低误解；也是最正当的上架定位 |

## 判断侧与场景的关系

判断题集（7 题）目前是按亲密对话校准的；场景 v1 只在**起草侧**注入附加段，判断题集不动。后续按场景扩展题集时（如客服场景的「客户是否在下单边缘」），以新增可选问题的方式叠加，保持旧题集校准不受污染。

## 隐私分级

各场景的数据出口一致：文字发送到用户自配的模型服务商。`social_a11y` 与 `support_agent` 在上架应用商店时按各自平台的无障碍/辅助功能政策单独评估；桌面端一律官网分发。
