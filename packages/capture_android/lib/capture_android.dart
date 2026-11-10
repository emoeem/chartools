import 'dart:async';
import 'dart:convert';

import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/services.dart';

/// 悬浮窗按钮动作：原生悬浮窗经快照通道（capture_android/snapshots）发回
/// `{type:'overlay_action', action, index}`，由 Dart 决定回填还是复制。
class OverlayAction {
  const OverlayAction({required this.action, required this.index});

  /// 'refill'（填入）| 'copy'（复制）。
  final String action;

  /// 候选下标：按最近一次 [CaptureAndroid.showSuggestions] 推入的列表解释。
  final int index;

  @override
  String toString() => 'OverlayAction($action #$index)';
}

/// Android 采集插件的 Dart 门面。
///
/// 采集服务（AccessibilityService，见 android/…/CaptureService.kt）在系统设置里
/// 启用后常驻：它把当前聊天窗口的 [ChatSnapshot] 经 EventChannel 推给 Dart，
/// Dart 侧用 core 流水线（[JevClient]）出建议，再把候选经
/// [CaptureAndroid.showSuggestions] 推回悬浮窗（OverlayController 只做展示，
/// 不调模型）；悬浮窗上的「填入/复制」按钮以 [OverlayAction] 事件回到 Dart。
/// 「回填」经 MethodChannel 交给 InputFiller —— 只填输入框，从不发送。服务与
/// Flutter 引擎是两个组件，通道由谁后到谁挂接（见 CaptureService.attachEngineChannels）。
class CaptureAndroid {
  static const MethodChannel _control =
      MethodChannel('capture_android/control');

  /// 插件自身通道：悬浮窗权限的查/跳（canDrawOverlays / openOverlaySettings）。
  /// 不走 _control——那条通道由 CaptureService 注册，服务未启用时整条不存在。
  static const MethodChannel _plugin = MethodChannel('capture_android');

  static const EventChannel _snapshots =
      EventChannel('capture_android/snapshots');

  /// 快照与悬浮窗动作共用一条原始事件流。原生侧 eventSink 是单字段（见
  /// CaptureService.streamHandler）：两次 receiveBroadcastStream() 会互相顶掉
  /// sink，所以这里只订阅一次、按事件里的 `type` 分流。最后一个监听者取消时
  /// 解绑原始订阅（onListen/onCancel），服务端 eventSink 跟着归零。
  late final StreamController<Object?> _events =
      StreamController<Object?>.broadcast(
          onListen: _attachRaw, onCancel: _detachRaw);

  StreamSubscription<Object?>? _rawSub;

  void _attachRaw() {
    _rawSub ??= _snapshots.receiveBroadcastStream().listen(
          _onRawEvent,
          onError: (Object e, StackTrace s) => _events.addError(e, s),
        );
  }

  Future<void> _detachRaw() async {
    await _rawSub?.cancel();
    _rawSub = null;
  }

  void _onRawEvent(Object? event) {
    // null / 空串 = 无快照（补发语义在原生侧）；作为 null 下传，由快照流过滤。
    if (event == null || (event is String && event.isEmpty)) {
      _events.add(null);
      return;
    }
    try {
      final raw = event is String ? event : event.toString();
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['type'] == 'overlay_action') {
        _events.add(OverlayAction(
          action: map['action'] as String? ?? '',
          index: (map['index'] as num?)?.toInt() ?? -1,
        ));
      } else {
        _events.add(_snapshotFromMap(map));
      }
    } catch (e) {
      // 与旧 map(_snapshotFromEvent) 语义一致：解析失败作为流错误下发。
      _events.addError(e);
    }
  }

  /// 快照流。服务端带签名去重（`signature()` 不变不发），并保留最近一条给
  /// 晚连接的 Dart 补发（pending-latest 语义）。空事件按「无快照」过滤；
  /// 悬浮窗动作事件由 [overlayActions] 分流，不会混进这里。
  Stream<ChatSnapshot> snapshots() => _events.stream
      .map<ChatSnapshot?>((e) => e is ChatSnapshot ? e : null)
      .where((s) => s != null)
      .cast<ChatSnapshot>();

  /// 悬浮窗按钮（填入/复制）事件流。与 [snapshots] 共用同一条 EventChannel
  /// 订阅（原生 eventSink 单字段），按 `type:'overlay_action'` 分流。
  Stream<OverlayAction> overlayActions() => _events.stream
      .map<OverlayAction?>((e) => e is OverlayAction ? e : null)
      .where((a) => a != null)
      .cast<OverlayAction>();

  /// 配置采集范围。[packages] 是聊天 App 的包名集合（如 com.tencent.mobileqq）；
  /// [ocrFallback] 开启后，无障碍树读不到正文时走截屏 OCR 兜底；[blocked] 是
  /// 采集应用黑名单（p0-plan ⑦，如支付宝/云闪付）：黑名单优先于白名单——包
  /// 在 [blocked] 里时，即使加进 [packages] 也不采。银行类前缀（com.android.bank）
  /// 的底线拦阻硬编码在 Kotlin 侧，不随本参数配置。
  Future<void> configure({
    required Set<String> packages,
    required bool ocrFallback,
    required Set<String> blocked,
  }) =>
      _control.invokeMethod<void>('configure', {
        'packages': packages.toList(),
        'ocrFallback': ocrFallback,
        'blocked': blocked.toList(),
      });

  /// 采集服务是否已连接并可用。
  Future<bool> isRunning() async =>
      await _control.invokeMethod<bool>('isRunning') ?? false;

  /// 跳转系统的无障碍设置页（用户在那里手动启用采集服务）。
  Future<void> openAccessibilitySettings() =>
      _control.invokeMethod<void>('openAccessibilitySettings');

  /// 是否已授予「显示在其他应用上层」（SYSTEM_ALERT_WINDOW）权限。悬浮窗开关
  /// 在申请此权限后才允许打开（无运行时对话框，只能引导去系统设置页）。
  Future<bool> canDrawOverlays() async =>
      await _plugin.invokeMethod<bool>('canDrawOverlays') ?? false;

  /// 跳转系统的悬浮窗权限设置页（ACTION_MANAGE_OVERLAY_PERMISSION，按本应用
  /// 包名直达开关）。
  Future<void> openOverlaySettings() =>
      _plugin.invokeMethod<void>('openOverlaySettings');

  /// 弹出/更新悬浮窗候选（服务已连接才有效；窗口加不出——无悬浮窗权限——
  /// 返回 false）。[list] 的下标即候选序号，[OverlayAction.index] 按它回传。
  /// [title] 是悬浮卡头部显示的会话标题。
  ///
  /// [mode] 是 B8 候选展示模式（[SettingsStore.displayMode] 的值）：
  /// `'primary'` = 主推第一张大卡、备选折叠两行小字（点按展开）；null 或
  /// `'all'` = 整列平铺（移植期行为，默认）。
  Future<bool> showSuggestions({
    required List<({String text, String strategy, double prob})> list,
    String? title,
    String? mode,
  }) async =>
      await _control.invokeMethod<bool>('showSuggestions', {
        'list': [
          for (final s in list)
            {'text': s.text, 'strategy': s.strategy, 'prob': s.prob},
        ],
        'title': title,
        'mode': mode,
      }) ??
      false;

  /// 收起悬浮窗（整个窗口移除；下次 showSuggestions 再弹）。
  Future<void> hideSuggestions() =>
      _control.invokeMethod<void>('hideSuggestions');

  /// 候选卡折回胶囊（control 通道 collapse）：只收卡不撤窗，胶囊留在屏上。
  /// 与 [hideSuggestions] 相对；「填入」成功后调这个，让出输入框和键盘给用户
  /// 检查/发送，同时悬浮球仍可随时再点开。
  Future<void> collapseSuggestions() => _control.invokeMethod<void>('collapse');

  /// 把建议文本填进当前会话的输入框（只填不发）。返回 false 表示没找到
  /// 可写的输入框，调用方应退回剪贴板复制。
  Future<bool> refill(String text) async =>
      await _control.invokeMethod<bool>('refill', {'text': text}) ?? false;

  /// 强制走一次整屏 OCR，返回快照；服务未连接时抛 MissingPluginException。
  Future<ChatSnapshot?> manualOcr() async =>
      _snapshotFromEvent(await _control.invokeMethod<Object?>('manualOcr'));

  /// 服务端发来的快照事件是 JSON 字符串；null / 空串按「无快照」处理。
  static ChatSnapshot? _snapshotFromEvent(Object? event) {
    if (event == null) return null;
    final raw = event is String ? event : event.toString();
    if (raw.isEmpty) return null;
    return _snapshotFromMap(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// 快照 JSON → [ChatSnapshot] 的解析收敛到 core 的 [ChatSnapshot.fromJson]
  /// （G3 通道契约的 Dart 侧：confidence/uncertain 与旧字段在同一处解析，
  /// 旧 JSON 无新字段时缺省 1.0/空表，行为不变）。
  static ChatSnapshot _snapshotFromMap(Map<String, dynamic> map) =>
      ChatSnapshot.fromJson(map);

  /// 仅供测试：直接走一次解析。生产代码不要调用。
  static ChatSnapshot? snapshotForTest(Object? event) =>
      _snapshotFromEvent(event);
}
