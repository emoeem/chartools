import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

// 注：toNativeUtf16 不是顶层导出，而是 StringUtf16Pointer 扩展的成员
//（ffi 2.2.0 lib/ffi.dart → export 'src/utf16.dart'）；show 组合器只能按名
// 收扩展本身、收不了扩展成员，故此处 show 的是扩展名而非方法名。
import 'package:ffi/ffi.dart' show Arena, calloc, StringUtf16Pointer, using;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show GlobalKey, NavigatorState, Route;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart';

/// Windows 全局热键控制器（默认 Ctrl+Alt+C）：在任意应用里按下热键，把主窗口
/// 切到前台、把桌面助手页顶到栈顶并聚焦其输入框（p0-plan「主动权在用户」——
/// 热键只负责唤起，不读剪贴板、不自动分析，也没有独立悬浮窗：Windows 只有一
/// 个主窗口，见任务契约 2/4）。
///
/// 实现选型（任务契约 1 的备选路线）：纯 Dart FFI 直调系统 user32.dll，不做
/// 任何原生编译——曾评估 hotkey_manager 0.3.0（版本约束与本机 Flutter
/// 3.47.9 / Dart 3.13.7 匹配），但其 Windows 实现经 nativeapi → cnativeapi
/// 走 native assets 构建链（cnativeapi 的 hook/build.dart 在构建期用
/// native_toolchain_c 编译 C++），等价于给工作区第三次引入「本机工具链缺失
/// 即构建挂」的坑（根 pubspec.yaml 已有两处为同一原因钉版的先例），故不采用。
/// 本文件用到的 win32 API 与常量逐一对过 6.4.0 缓存源码（下文按行引用）。
///
/// 线程模型（RegisterHotKey 的硬约束）：WM_HOTKEY 只投递给**调用
/// RegisterHotKey 的那条线程**的消息队列，且必须由同线程的 GetMessage 取出。
/// Flutter 的 Dart UI 线程不跑 Win32 消息泵，主 isolate 不能直接注册；因此
/// [HotkeyController.setEnabled] 用 [Isolate.spawn] 起一条专用泵线程
/// （[_pumpMain]）：从 RegisterHotKey 到消息循环退出之间没有任何 await，
/// isolate 不会在同步执行中切换底层线程，注册与泵因此固定在同一条 OS 线程。
/// 关停走 PostThreadMessage(WM_QUIT)——GetMessage 返回 0，循环退出并在
/// finally 里 UnregisterHotKey（勿用 ReceivePort 回传关停指令：泵线程阻塞在
/// 同步 FFI 调用里，永远不会回来取端口消息）。
///
/// 状态契约（UI 只看这三份）：
/// - [enabled]：热键当前已注册生效（开关绑定它，注册失败弹回 false）。
/// - [error]：注册失败的可见文案（null = 无错），UI 必须展示，不许吞。
/// - [activationTick]：热键触发信号（计数器），页面监听它取走 [pendingFocus]。
class HotkeyController {
  HotkeyController._();

  /// 应用级单例：泵线程全生命周期只有一条，开关在桌面助手页上。
  static final HotkeyController instance = HotkeyController._();

  /// 平台门控：热键是 Windows 桌面能力，其它平台（含 Web）入口全部隐藏、
  /// 控制器所有方法为空操作——调用方无须再写平台判断。
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// 热键组合与键值的唯一事实来源，UI 文案（[hotkeyLabel]）与注册共用。
  /// 数值来源（win32 6.4.0 缓存源码）：MOD_CONTROL=2 / MOD_ALT=1 /
  /// MOD_NOREPEAT=0x4000（enums.g.dart:6416-6420），VK_C=67（enums.g.dart:16456，
  /// 即 'C'）。MOD_NOREPEAT 让按住不放不产生连发触发。
  static const int _modifiers = 0x0002 | 0x0001 | 0x4000;
  static const int _vk = 0x43;

  /// 注册 id：线程内唯一即可，0x4343 = "CC"。
  static const int _hotkeyId = 0x4343;

  /// 热键的展示文案（开关标题 / 失败提示共用，改 [_modifiers]/[_vk] 时同步）。
  static const String hotkeyLabel = 'Ctrl + Alt + C';

  /// 偏好存档键：开关状态独立于 SettingsStore 的整包 JSON（该文件不在本任务
  /// 文件清单里，跨文件改动须走契约，故热键开关自持一个键）。存的是用户显式
  /// 选择；读不到（首次启动/平台通道不可用）按默认开处理——与 UI 默认一致。
  /// 用户把开关关掉即写 false，等价于删除这条偏好（G7：可查看/修改/删除）。
  static const String _prefsKey = 'desktopAssistant.hotkeyEnabled';

  /// 桌面助手页的路由名：激活时 popUntil 以此识别「页面已在栈上」。由 main.dart
  /// 在构建路由时挂到 RouteSettings（本任务对 main.dart 的最小越界，见 notes）。
  static const String assistantRouteName = 'desktop-assistant';

  // ---------------------------------------------------------------- UI 状态

  /// 热键当前已注册生效。开关绑定它：注册失败时保持/弹回 false。
  final ValueNotifier<bool> enabled = ValueNotifier(false);

  /// 注册失败的用户可见文案（null = 无错）。任务契约 3：失败必须给可见提示。
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  /// 热键触发信号：每次触发 +1。页面（若在树上）监听它并取走 [pendingFocus]。
  final ValueNotifier<int> activationTick = ValueNotifier(0);

  /// 一次未消费的聚焦请求。激活时置位；页面监听或 initState 里经
  /// [consumePendingFocus] 取走——后者覆盖「本次触发恰好把页面新推入栈」
  /// 的路径（新页面的监听注册晚于信号发出，靠 initState 补票）。
  bool pendingFocus = false;

  /// 取走聚焦请求：有则清位并返回 true（取走即清，避免旧信号滞留）。
  bool consumePendingFocus() {
    final value = pendingFocus;
    pendingFocus = false;
    return value;
  }

  // ------------------------------------------------------- 页面/导航接插件

  /// 导航器 key：由 main.dart 挂到 MaterialApp.navigatorKey（同上，最小越界）。
  /// 没挂上时 activation 退化成「只切窗口前台」，不导航、不崩。
  final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>(debugLabel: 'hotkey-navigator');

  /// 路由工厂：main.dart 在启动时注入（它才拥有 SettingsStore 与页面参数）。
  Route<void> Function()? _routeFactory;

  /// 页面是否在树上（DesktopAssistantPage initState/detach 维护）。页面在树
  /// 但被设置页等盖住时，激活走 popUntil 把它顶回栈顶。
  bool _pageAttached = false;

  /// 页面生命周期挂钩：initState 调 attach，dispose 调 detach。
  void attachPage() => _pageAttached = true;
  void detachPage() => _pageAttached = false;

  // ----------------------------------------------------------------- 开关

  /// 应用启动入口：main.dart 在 store.load() 之后调用（Windows 才生效）。
  /// 注入路由工厂并按存档恢复开关（默认开）。
  Future<void> startup({required Route<void> Function() routeFactory}) async {
    if (!isSupported) return;
    _routeFactory = routeFactory;
    var on = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      on = prefs.getBool(_prefsKey) ?? true;
    } catch (_) {
      // 平台通道不可用：按默认开处理（UI 默认与之一致）。
    }
    if (on) await setEnabled(true, persist: false);
  }

  /// 开关热键：value=true 起泵线程注册；false 发 WM_QUIT 关停（泵线程在
  /// finally 里注销热键后自行退出）。幂等；失败置 [error] 且 [enabled] 为 false。
  Future<void> setEnabled(bool value, {bool persist = true}) async {
    if (!isSupported) return;
    if (value == _running) {
      if (persist) unawaited(_persist(value));
      return;
    }
    if (value) {
      error.value = null;
      final gen = ++_generation;
      _starting = true;
      final ready = ReceivePort();
      late final StreamSubscription<dynamic> sub;
      sub = ready.listen((message) {
        if (message is! _PumpEvent) return;
        if (message is _PumpReady) {
          _starting = false;
          if (gen != _generation) {
            // 关停先于就绪到达（快节奏开关）：让刚注册成功的线程自停，
            // 不更新任何状态。
            PostThreadMessage(message.threadId, WM_QUIT, WPARAM(0), LPARAM(0));
            return;
          }
          _pumpThreadId = message.threadId;
          enabled.value = true;
        } else if (message is _PumpFailed) {
          _starting = false;
          if (gen != _generation) return;
          enabled.value = false;
          error.value = _failureText(message.win32Error);
        } else if (message is _PumpActivated) {
          if (gen != _generation) return;
          _handleActivated();
        } else if (message is _PumpStopped) {
          // 泵线程退出（唯一收尾事件）：收掉监听与端口。cancel 的 Future
          // 无需等待（此监听此后不会再收事件），显式丢弃避免 lint 噪音。
          unawaited(sub.cancel());
          ready.close();
        }
      });
      try {
        await Isolate.spawn(
          _pumpMain,
          _PumpConfig(
              ready: ready.sendPort,
              id: _hotkeyId,
              modifiers: _modifiers,
              vk: _vk),
          debugName: 'hotkey-pump',
        );
      } catch (e) {
        _starting = false;
        _pumpThreadId = null;
        await sub.cancel();
        ready.close();
        enabled.value = false;
        error.value = '热键注册失败：无法启动热键线程（$e）。';
        return;
      }
    } else {
      // 先失效代际再发退出指令：迟到的事件（含刚就绪的线程）一律自停。
      _generation++;
      final tid = _pumpThreadId;
      _pumpThreadId = null;
      _starting = false;
      enabled.value = false;
      if (tid != null) {
        PostThreadMessage(tid, WM_QUIT, WPARAM(0), LPARAM(0));
      }
    }
    if (persist) unawaited(_persist(value));
  }

  bool _starting = false;

  /// 泵线程是否活着（含正在启动）。开关幂等与竞态判断的依据。
  bool get _running => _starting || _pumpThreadId != null;

  /// 代际计数：每次 enable/disable 递增，泵线程事件按 spawn 时记下的代号对账，
  /// 迟到的事件直接丢弃（或让线程自停），杜绝「关了又活过来」。
  int _generation = 0;

  int? _pumpThreadId;

  /// 开关状态落盘；失败静默（内存态仍正确，下次保存再写）。
  Future<void> _persist(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, value);
    } catch (_) {
      // 平台通道不可用（测试环境等）：留在内存态即可。
    }
  }

  /// 注册失败的可见文案。1409 = ERROR_HOTKEY_ALREADY_REGISTERED
  /// （win32 6.4.0 enums.g.dart:19406）。
  String _failureText(int win32Error) {
    if (win32Error == 1409) {
      // 常见原因有二：别的程序占了这个组合；或上一条泵线程刚被关停、还没走完
      // UnregisterHotKey（毫秒级窗口）。文案把两个出口都给用户。
      return '热键注册失败：$hotkeyLabel 已被其它程序占用（若刚关闭过开关，'
          '等一瞬再打开即可）。';
    }
    if (win32Error < 0) return '热键注册失败。';
    return '热键注册失败（Win32 错误码 $win32Error）。';
  }

  // ------------------------------------------------------- 激活：切前台+导航

  /// 热键触发（主 isolate 收到泵线程的激活事件）：切窗口前台 → 页面顶到栈顶
  /// → 发聚焦信号。三步都不读剪贴板、不触发分析（任务契约 4）。
  void _handleActivated() {
    _bringWindowToFront();
    final nav = navigatorKey.currentState;
    if (_pageAttached) {
      // 页面在树上（可能被设置页等盖住）：popUntil 把它顶回栈顶，其余路由
      // 全部收回。路由本身都是 void 的 fire-and-forget，弹出无返回值问题。
      nav?.popUntil((route) =>
          route.isFirst || route.settings.name == assistantRouteName);
    } else if (nav != null && _routeFactory != null) {
      nav.push(_routeFactory!());
    }
    pendingFocus = true;
    activationTick.value++;
  }

  /// 把 runner 主窗口带到前台。窗口坐标：类名 FLUTTER_RUNNER_WIN32_WINDOW
  /// （windows/runner/win32_window.cpp:19）、标题 chartools_app
  /// （windows/runner/main.cpp:30，Create 的实参），二者都是仓库内常量；
  /// 用类名+标题双条件 FindWindow，避免误中其它 Flutter 应用的窗口。
  void _bringWindowToFront() {
    using((Arena arena) {
      final cls =
          PCWSTR('FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: arena));
      final title = PCWSTR('chartools_app'.toNativeUtf16(allocator: arena));
      final found = FindWindow(cls, title);
      final hwnd = found.value;
      if (hwnd.address == 0) return; // 找不到就静默返回（窗口尚未建立等）。
      if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE); // 最小化先还原。
      ShowWindow(hwnd, SW_SHOW);
      // 前台锁定：全局热键按下后系统通常已给本进程前台权，SetForegroundWindow
      // 直接成功；若仍被拒（前台锁定策略），退而把当前前台窗口的输入队列临时
      // 接进来再激活——这是 Win32 时代传下来的标准兜底。
      final fg = GetForegroundWindow();
      if (fg.address == hwnd.address) {
        SetForegroundWindow(hwnd);
        return;
      }
      final thisThread = GetCurrentThreadId();
      final fgThread = GetWindowThreadProcessId(fg, null);
      AttachThreadInput(thisThread, fgThread, true);
      SetForegroundWindow(hwnd);
      AttachThreadInput(thisThread, fgThread, false);
    });
  }
}

// ================================================================ 泵线程侧

/// spawn 参数：不可变，跨 isolate 传递（同 isolate group，直接传对象）。
class _PumpConfig {
  const _PumpConfig({
    required this.ready,
    required this.id,
    required this.modifiers,
    required this.vk,
  });

  /// 泵线程 → 主 isolate 的事件端口（就绪/失败/触发都走它）。
  final SendPort ready;
  final int id;
  final int modifiers;
  final int vk;
}

/// 泵线程事件（sealed：主 isolate 侧按类型逐一分派）。
sealed class _PumpEvent {
  const _PumpEvent();
}

/// 热键注册成功，附注册线程 id（主 isolate 用它发 WM_QUIT）。
class _PumpReady extends _PumpEvent {
  const _PumpReady(this.threadId);
  final int threadId;
}

/// 热键注册失败，附 GetLastError 的错误码。
class _PumpFailed extends _PumpEvent {
  const _PumpFailed(this.win32Error);
  final int win32Error;
}

/// 热键按下。
class _PumpActivated extends _PumpEvent {
  const _PumpActivated();
}

/// 泵线程已退出（热键已注销）：主 isolate 收到后收掉监听与端口，开关循环
/// 不留悬空的 ReceivePort。端口按 enable 分配（代际隔离），旧线程的收尾
/// 事件只会进旧监听，不会污染新一轮状态。
class _PumpStopped extends _PumpEvent {
  const _PumpStopped();
}

/// 泵线程入口：注册热键 → 取本线程 id 上报 → GetMessage 循环 → 退出时注销。
/// 全程无 await（见类文档的线程模型说明）。本函数用到的 win32 绑定签名均按
/// 6.4.0 缓存源码核对：RegisterHotKey/UnregisterHotKey（HWND? 可空 →
/// 线程级注册，user32.g.dart:7184/9513）、GetMessage（user32.g.dart:3897，
/// 包装器把 0=WM_QUIT 折叠为 value=false；-1 异常也折叠为 true，但参数合法
/// 时 GetMessage 不会持续返回 -1）、MSG（structs.g.dart:12710）。
///
/// 生命周期严谨性：注册成功与否都从同一条路径退出——finally 负责
/// 「有注册必注销、有端口必收尾」两件事，失败/异常分支只补发失败事件。
void _pumpMain(_PumpConfig cfg) {
  final msg = calloc<MSG>();
  // 热键是否已注册成功：finally 据此决定要不要 UnregisterHotKey。
  var registeredOk = false;
  try {
    final registered =
        RegisterHotKey(null, cfg.id, HOT_KEY_MODIFIERS(cfg.modifiers), cfg.vk);
    if (registered.value != true) {
      // GetLastError 已由 Win32Result 捕获（user32.g.dart:7191-7193）。
      cfg.ready.send(_PumpFailed(registered.error));
      return;
    }
    registeredOk = true;
    cfg.ready.send(_PumpReady(GetCurrentThreadId()));
    for (;;) {
      final got = GetMessage(msg, null, 0, 0);
      // value=false ⇔ GetMessage 返回 0 ⇔ 收到 WM_QUIT（关停路径）。
      if (got.value != true) break;
      final int message = msg.ref.message;
      if (message == WM_HOTKEY) {
        cfg.ready.send(const _PumpActivated());
        continue;
      }
      TranslateMessage(msg);
      DispatchMessage(msg);
    }
  } catch (_) {
    // 兜底：注册之后的意外异常不能让线程无声死亡——报给主 isolate
    // （错误码 -1 走通用文案）。send 到已关端口会被静默丢弃，无竞态。
    cfg.ready.send(const _PumpFailed(-1));
  } finally {
    // 无论是正常关停、注册失败还是异常退出：
    // 注册过就必须注销（进程还活着、线程要没了），端口必须收尾。
    if (registeredOk) UnregisterHotKey(null, cfg.id);
    calloc.free(msg);
    cfg.ready.send(const _PumpStopped());
  }
}
