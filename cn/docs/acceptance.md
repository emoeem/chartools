# 验收标准（公共尺子）

所有任务以此为准。**建者不自证，贴真实输出。** 当前版本 2.0；功能以[功能介绍](feature-guide.md)为准。

## A. 构建与单测

本机（Linux，仓库 `/home/emo/code/chartools/cn`）：

```
cd /home/emo/code/chartools/cn
bash gradlew :app:testDebugUnitTest :app:assembleDebug
```

Windows 构建机（历史路径）：

```
H:\ai_tool\jev-android\gradlew.bat :app:testDebugUnitTest assembleDebug
```

单测 0 失败、构建零 error。产物 `app/build/outputs/apk/debug/app-debug.apk` 存在。新增 / 修改行为必须带 JVM 单测；Android 框架接线（Handler、Service、悬浮窗）单测覆盖不到的，要在报告里写明真机验证结果或缺口。

## C. Jev 判断层

```
python tools/jev/calibrate.py
```
输出每道题在标注集上的命中率表格 + 置信度分布。要求：
- 标注集不少于 20 条中文对话片段
- `danger_level` 打分与人工标注的平均绝对误差 < 1.0 档
- `true_intent` / `she_needs` 命中率 ≥ 60%
- 全部请求 HTTP 200，无 key 泄漏到 stdout

## D. 真机冒烟（最后一次验证，只跑一遍）

1. 对方发来新消息后 **1.5 秒内**悬浮窗出现分析，候选回复不少于 3 条且已排序
2. 点"填入"后输入框出现文本，**且未发送**
3. 自己发的消息不触发；切换会话上下文重置；App 切后台悬浮窗隐藏
4. 密钥不出现在 logcat；断网时给可读错误不崩溃
5. 10 分钟静默期 Jev 调用次数为 0
