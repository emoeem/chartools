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
  /// control 通道名（平台 → Dart 的重放请求也走它）。与 Kotlin 侧
  /// CaptureService.CONTROL_CHANNEL（CaptureService.kt:59）同名同值；
  /// 改任何一侧必须两侧同步（Dart 测试与 Kotlin ConfigureReplayTest 各自钳
  /// 字面量）。
  static const String controlChannelName = 'capture_android/control';

  /// 服务 → Dart 的重放请求方法名。与 Kotlin 侧
  /// CaptureService.REQUEST_CONFIGURE_METHOD（CaptureService.kt:68）同名同值。
  static const String requestConfigureMethod = 'requestConfigure';

  /// Dart → 服务的悬浮窗防截屏开关方法名（fix(kimi-review #11)）。与 Kotlin 侧
  /// CaptureService.SET_SECURE_METHOD（handleControl 的分支键）同名同值；
  /// 参数就是 bool 本身（Kotlin 侧 `call.arguments as? Boolean`）。改任何一侧
  /// 必须两侧同步（Kotlin SetSecureContractTest 与本包测试互钳）。
  static const String setSecureMethod = 'setSecure';

  /// Dart → 服务的悬浮窗防截屏状态回读方法名（fix(#9 K-2)）。与 Kotlin 侧
  /// CaptureService.IS_SECURE_METHOD（handleControl 的分支键）同名同值：无参数、
  /// 返回 bool（OverlayController 当前内存态，窗口未建也返回已记录的开关值）。
  /// 采集页开关用它做「期望值 vs 服务回读值」比较——服务重启后原生状态回默认，
  /// 本地状态可能与之相反，早退必须以回读为准而不是本地字段。改任何一侧必须
  /// 两侧同步（Kotlin SetSecureContractTest 的回放场景与本包测试互钳）。
  static const String isSecureMethod = 'isSecure';

  static const MethodChannel _control = MethodChannel(controlChannelName);

  /// 插件自身通道：悬浮窗权限的查/跳（canDrawOverlays / openOverlaySettings）。
  /// 不走 _control——那条通道由 CaptureService 注册，服务未启用时整条不存在。
  static const MethodChannel _plugin = MethodChannel('capture_android');

  static const EventChannel _snapshots =
      EventChannel('capture_android/snapshots');

  /// fix(kimi-review #2)：服务侧 configure 重放请求的 Dart 接收端。
  ///
  /// 原生在「服务已连接 + 引擎已挂接」的汇聚点（CaptureService.attachEngineChannels）
  /// 经 control 通道向 Dart 发 `requestConfigure`（fire-and-forget：无参数、
  /// 无回调、Dart 未接住就丢弃，服务侧不等待不重试——Kotlin 侧由
  /// ConfigureReplayTest 钳住）。本回调非空时请求交它处理：应用层（采集页
  /// _pushConfigure）用当前生效的采集配置幂等重发 [configure]，覆盖「先开
  /// 采集页、后启无障碍」这条最常见路径下首次 configure 打空（服务未连）
  /// 的静默失效。fix(#9 K-2) 起 [configure] 载荷含 `secure`：服务重启后原生
  /// FLAG_SECURE（内存态，回默认关）随这次重放自动恢复，采集页开关不再与
  /// 实际相反。回调由采集页进页时设置、退出时清空；null = 请求被丢弃
  /// （无页面持有配置，下次进页 initState 会重新下发）。
  ///
  /// 通道契约两侧写死：通道名 `capture_android/control` =
  /// CaptureService.CONTROL_CHANNEL，方法名 `'requestConfigure'` =
  /// CaptureService.REQUEST_CONFIGURE_METHOD；改任何一侧必须两侧同步。
  static Future<void> Function()? onConfigureReplay;

  static bool _controlHandlerAttached = false;

  /// 平台 → Dart 方向的 control 通道只服务重放请求：未知方法按 null 应答、
  /// 不抛 notImplemented——采集链路不该被一个未知反向方法打断。handler 是
  /// 进程级单份（const 通道 + 全局 messenger），首个实例挂上即生效，后续
  /// 挂接是幂等 no-op。
  void _attachControlHandler() {
    if (_controlHandlerAttached) return;
    _controlHandlerAttached = true;
    _control.setMethodCallHandler(handleControlMethodCall);
  }

  /// control 通道「平台 → Dart」方向的分发体（fix(kimi-review #2)）：
  /// `requestConfigure` 重放请求交 [onConfigureReplay]，其余一律 null 应答。
  /// 供 [_attachControlHandler] 注册，也作为测试缝——不碰二进制 messenger，
  /// 纯 Dart 可直调，套件加载期零 binding 副作用（第 2 轮门禁实测：
  /// 测试文件在加载期初始化 flutter_test binding 曾随 runner 的套件派生
  /// 偶发 "Connection closed before test suite loaded"，故契约测试不走真
  /// 通道，见 capture_android_test.dart）。
  // 仅供测试与 [_attachControlHandler]：生产代码不要直接调用。
  static Future<Object?> handleControlMethodCall(MethodCall call) async {
    if (call.method == requestConfigureMethod) {
      final replay = onConfigureReplay;
      if (replay != null) await replay();
    }
    return null;
  }

  CaptureAndroid() {
    _attachControlHandler();
  }

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
  ///
  /// [secure] 是悬浮窗防截屏（FLAG_SECURE）的期望值（fix(#9 K-2)）：随本载荷
  /// 进 configure，Kotlin 侧落为 overlay.setSecure——服务重连重放（[onConfigureReplay]
  /// → 采集页 _pushConfigure）时用它把原生内存态恢复成 Dart 侧当前值，服务重启
  /// 后 FLAG_SECURE 不再静默丢失。载荷契约：`{packages, ocrFallback, blocked,
  /// secure}`；`secure` 键在旧调用方/旧载荷缺省时按 false 处理（Kotlin 侧缺省
  /// 语义，向后兼容）。configure 是幂等重放：同一载荷重复下发无副作用。
  Future<void> configure({
    required Set<String> packages,
    required bool ocrFallback,
    required Set<String> blocked,
    required bool secure,
  }) =>
      _control.invokeMethod<void>('configure', {
        'packages': packages.toList(),
        'ocrFallback': ocrFallback,
        'blocked': blocked.toList(),
        'secure': secure,
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

  /// 悬浮窗防截屏开关（kimi-review #11）：true = 给悬浮窗窗口加 WindowManager
  /// 的 FLAG_SECURE——系统截图与屏幕录制都拍不到悬浮窗内容（候选是第三方
  /// 对话明文，录屏可整段带走）；false = 关闭，恢复可拍。默认关（Kotlin 侧
  /// OverlayController 缺省 false，窗口加 flag 与否由它落地）。
  ///
  /// 通道契约写死（与 Kotlin 侧对齐）：control 通道方法 `'setSecure'`，参数
  /// 就是 bool 本身——Kotlin 侧 `call.arguments as? Boolean`，由
  /// CaptureService.handleControl 的 'setSecure' 分支转给
  /// OverlayController.setSecure。开关状态在原生侧是内存态（采集服务重启回
  /// 默认关），Dart 侧不缓存——重启后的恢复靠 [configure] 载荷里的 `secure`
  /// 随服务连接重放（fix(#9 K-2)），当前实际状态用 [isSecure] 回读。
  ///
  /// control 通道由采集服务注册：服务未连接时这里抛 MissingPluginException
  /// （通道在而分支未接时是 PlatformException(notImplemented)），由调用方
  /// 兜底——采集页的开关保持原位并提示，不静默。
  Future<void> setSecure(bool secure) =>
      _control.invokeMethod<void>(setSecureMethod, secure);

  /// 回读服务侧悬浮窗防截屏的当前状态（fix(#9 K-2)）：control 通道
  /// `'isSecure'`，无参数、返回 bool——OverlayController 的当前内存态（窗口
  /// 未建时返回已记录的开关值：setSecure 先记状态、建窗时按它补 FLAG_SECURE，
  /// 回读值与将来建窗的窗口 flags 一致）。
  ///
  /// 用途：采集页防截屏开关的早退判定——「期望值 vs 服务回读值」不一致才下发
  /// [setSecure]（服务重启后本地状态是陈旧的，早退以回读为准）。通道契约与
  /// Kotlin 侧 CaptureService.IS_SECURE_METHOD 同名同值，改任何一侧必须两侧
  /// 同步（Kotlin SetSecureContractTest 互钳）。
  ///
  /// 与 [setSecure] 同一条 control 通道：服务未连接时抛 MissingPluginException，
  /// 由调用方兜底。
  Future<bool> isSecure() async =>
      await _control.invokeMethod<bool>(isSecureMethod) ?? false;

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
