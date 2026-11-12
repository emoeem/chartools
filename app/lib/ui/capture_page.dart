import 'package:capture_android/capture_android.dart';
import 'package:chartools_core/chartools_core.dart';
// MissingPluginException 只在 services 库导出（material/widgets 不转发它）；
// fix(#11 P0-1 配套) 的错误分类要区分「插件未就绪」与一般错误。
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter/material.dart';

import '../application/capture_session.dart';
// #6 联系人档案（A 的 ContactStore/ContactProfile）：本文件还承载联系人与
// G7 偏好的共享 UI（ContactSection / StagedFactBar / 两个面板），桌面流页
// 从这里 import——两个文件同属交互写手，避免复制两份实现。候选区的共用
// widget（候选卡 / B7 / B8 / G1 预览 / G7 反馈标签 / 记住这条）抽去了
// widgets/candidate_list.dart（kimi-review #16），两页只传数据与回调。
import '../application/contact_store.dart';
import '../application/settings_store.dart';
import 'widgets/candidate_list.dart';

/// 采集助手页（Android）：无障碍开关入口、采集范围配置、悬浮窗开关、实时
/// 快照与建议。
///
/// 建议在页面上完整展示，同时（开关打开时）推到悬浮窗 OverlayController；
/// 「回填」把候选填进聊天输入框，从不自动发送。
///
/// fix(#11 P0-3)：本页 State 同时挂了 WidgetsBindingObserver 与 RouteAware——
/// 前者覆盖「跳系统设置授权后返回应用」（lifecycle paused→resumed），后者覆盖
/// 「本页之上的应用内路由 pop 回来」。RouteAware 生效有一个前提：[routeObserver]
/// 必须注册进 MaterialApp 的 navigatorObservers（main.dart 一行
/// `navigatorObservers: [CapturePage.routeObserver]`）。未注册时订阅是惰性的
/// （didPopNext 不会来，页面刷新退回 lifecycle 一条腿），不报错。
class CapturePage extends StatefulWidget {
  const CapturePage({
    super.key,
    required this.config,
    required this.relationship,
    required this.overlayEnabled,
    this.displayMode,
    this.scenarioId,
    this.blockedPackages,
    this.contactStore,
    this.preferences,
    this.persistPreferences,
    this.usage,
    this.writeCheckpoint,
    this.sessionCheckpoint,
  });

  /// fix(#11 P0-3)：本页 RouteAware 订阅的路由观察者（进程一份，静态持有）。
  /// RouteObserver 必须由 MaterialApp 的 navigatorObservers 引用才会观测路由
  /// 变化——观察者实例只能被接线方（main.dart）共享出来，本页自己够不着
  /// MaterialApp。泛型取 `ModalRoute<void>`：MaterialPageRoute 与对话框/底部
  /// 面板的 Route 都是其子类型，弹层关闭（didPopNext）也会触发刷新。
  static final RouteObserver<ModalRoute<void>> routeObserver =
      RouteObserver<ModalRoute<void>>();

  final ValueNotifier<JevConfig> config;

  /// 与对方的关系：与设置页共享同一份 [SettingsStore.relationship]，采集页
  /// 输入框写的就是流水线读的那个值。
  final ValueNotifier<String> relationship;

  /// 悬浮窗开关：与设置页共享同一份 [SettingsStore.overlayEnabled]，也是
  /// [CaptureSession] 推悬浮窗用的开关——单一事实来源，没有第二轨。
  final ValueNotifier<bool> overlayEnabled;

  /// 候选展示模式（p0-plan B8）：与设置页共享同一份
  /// [SettingsStore.displayMode]，primary = 主推排序第一张大卡、备选折叠；
  /// all = 全部平铺。可选注入——main.dart 传入 store.displayMode；未传时按
  /// 产品默认（displayModePrimary）渲染。
  final ValueNotifier<String>? displayMode;

  /// 场景选择（fix(#11 P0-N) 独立复核补接）：与设置页/桌面流共享同一份
  /// [SettingsStore.scenarioId]——引导页「选场景」写入的那份 notifier，本页
  /// 只读。透传给 [CaptureSession.scenarioId]，每轮起草经
  /// [CaptureSession.resolveScenario] 现查场景模板，客服坐席/外语陪练/社交
  /// 辅助（无障碍）等非默认场景的附加段随采集流的起草请求出网。未传（旧
  /// 构造方/工具页测试）时全部轮次无场景，请求与缓存键和接入前同构。
  final ValueNotifier<String>? scenarioId;

  /// 采集应用黑名单（p0-plan ⑦，隐私底线清单）：可选注入——main.dart 传入
  /// [SettingsStore.blockedPackages]，与设置页共享同一份（单一事实来源）。
  /// 本页「采集范围」卡的黑名单区读写它：点按标签移除、输入框添加（改动
  /// 立即经 [_pushConfigure] 下发）。未传时编辑落在页面本地兜底集合，初始
  /// 值为 [SettingsStore.defaultBlockedPackages]。黑名单优先于白名单（由
  /// Kotlin 侧 isBlocked() 保证）；每次 [_pushConfigure] 都以当前值为准。
  final ValueNotifier<Set<String>>? blockedPackages;

  /// #6 联系人档案（A 的 ContactStore）：可选注入——main.dart 传入共享实例
  /// （与设置侧共享同一份持久化）。未注入（工具页直开本页的测试场景）时整个
  /// 联系人区不渲染，会话不带联系人上下文（与基线行为一致）。
  final ContactStore? contactStore;

  /// G7 结构化偏好（C 的 PreferenceProfile）：可选注入。未注入时候选卡的
  /// 反馈标签行与「查看我的偏好」入口不渲染。
  final PreferenceProfile? preferences;

  /// G7 偏好落盘回调（main.dart 注入）：record/clear 之后由页面触发——
  /// PreferenceProfile 只给 toJson/fromJson（core 不落盘），存取时机在 app 层。
  final void Function()? persistPreferences;

  /// C9 使用统计（可选注入，[SettingsStore.usage] 同一份实例）：传进
  /// [CaptureSession] 后四条路由的打点写进它，设置页统计卡读同一份对象。
  /// null = 不打点（工具页直开的测试场景，与接入前逐字节一致）。
  final UsageStats? usage;

  /// C10 会话检查点的落盘句柄（main.dart 传 [SettingsStore.saveSessionCheckpoint]）：
  /// 撕给 [CaptureSession]，快照进门/切换联系人时写档。null = 只算不写（测试场景）。
  final CheckpointWriter? writeCheckpoint;

  /// C10 进页时的检查点存档快照（main.dart 传 store.sessionCheckpoint——store
  /// 已在 main() 里 load 完）。非空且非空检查点时，进页弹「待确认恢复上次会话」
  /// 对话框（C10 硬约束：恢复必须过用户确认，不静默恢复）。确认后经
  /// [CaptureSession.restoreCheckpoint] 回填，再写 null 清档。
  final Map<String, dynamic>? sessionCheckpoint;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

/// fix(#11 P0-3)：挂 WidgetsBindingObserver（应用进出前台）与 RouteAware
/// （应用内路由往返），两条腿都汇进 [_refreshAfterPermissionRoundTrip]。
class _CapturePageState extends State<CapturePage>
    with WidgetsBindingObserver, RouteAware {
  late final CaptureSession _session;
  late final TextEditingController _relationship;

  /// ③ 补充背景输入框：逐键写进 [CaptureSession.extraContext]，清空即移除。
  final TextEditingController _extra = TextEditingController();

  bool _serviceRunning = false;
  bool _ocrFallback = true;

  /// fix(#11 P0-3)：通知权限（POST_NOTIFICATIONS，Android 13+ 运行时授权）
  /// 的当前状态。null = 未知（通道不可用 / 还没查到，与引导页的权限行同一
  /// 口径）；false = 未开启——13+ 上保活前台通知会被系统整条隐藏。
  bool? _notificationsOn;

  /// #11 悬浮窗防截屏（FLAG_SECURE）开关，默认关。页面本地状态（不落盘），
  /// 是服务连接期间原生开关的「期望值」单一事实来源：原生状态存服务进程内存，
  /// 服务重启回默认关——fix(#9 K-2) 起把它随 [_pushConfigure] 的 configure
  /// 载荷（`secure` 键）一起下发，服务重连重放（[CaptureAndroid.onConfigureReplay]
  /// 触发的幂等重发）会把原生 FLAG_SECURE 恢复成本字段的当前值，开关显示不再
  /// 与实际相反；拨动开关时以 [CaptureAndroid.isSecure] 的服务回读值做早退
  /// 判定（见 [_toggleOverlaySecure]），本地字段陈旧也不会阻断重新下发。仍不
  /// 落盘：应用进程重启回默认关（与原生缺省一致），持久化仍是后续项。
  bool _overlaySecure = false;

  /// A3「学习我的说话方式」开关：写入 [CaptureSession.styleLearning]，下一轮
  /// 起草生效。
  bool _styleLearning = false;

  /// ⑦ 黑名单「添加包名」输入框：回车或「添加」按钮把包名写进黑名单。
  final TextEditingController _blockedInput = TextEditingController();

  /// ⑦ 黑名单的本地兜底集合：main.dart 未注入 [CapturePage.blockedPackages]
  /// 时（工具页直开本页的测试场景）编辑落在这里；正常注入时只读不写——
  /// 编辑一律写回共享 notifier（与设置页持久化同一份）。
  Set<String> _localBlocked = Set.of(SettingsStore.defaultBlockedPackages);

  /// 当前生效的黑名单：注入时以共享 notifier 为单一事实来源。
  Set<String> get _effectiveBlocked =>
      widget.blockedPackages?.value ?? _localBlocked;

  /// ⑦ 黑名单增删的唯一写入口：写回（notifier 或本地兜底）→ 重绘 → 立即
  /// 重推 configure（黑名单优先于白名单由 Kotlin 侧保证，改完即生效）。
  /// fix(#11 P0-1 配套)：用户动作，下发失败要可见（reportFailure）。
  void _commitBlocked(Set<String> next) {
    final notifier = widget.blockedPackages;
    if (notifier != null) {
      notifier.value = next;
    } else {
      _localBlocked = next;
    }
    setState(() {});
    _pushConfigure(reportFailure: true);
  }

  /// ⑦ 「添加包名」：trim 后入黑名单；空串与重复项直接忽略，输入框清空。
  void _addBlocked() {
    final pkg = _blockedInput.text.trim();
    if (pkg.isEmpty || _effectiveBlocked.contains(pkg)) {
      _blockedInput.clear();
      return;
    }
    _commitBlocked(Set.of(_effectiveBlocked)..add(pkg));
    _blockedInput.clear();
  }

  /// B8：被点开展开的备选卡下标（主推模式下备选默认折叠为两行小字）。
  final Set<int> _expandedCandidates = {};

  /// v1 适配清单（与旧仓库 ChatApps 一致的子集，包名按需增减）。
  /// fix(kimi-review #22 复查)：抖音移出本清单——Kotlin 侧 ChatApps 没有它的
  /// 适配器（ChatApps.kt 只注册了微信的 WeChatOcrAdapter），勾选后事件照常进
  /// configuredPackages，maybeCapture 在 ChatApps.forPackage 返回 null 处直接
  /// return，自动采集静默不生效，UI 承诺不兑现。降到 [_manualOcrOnlyApps]
  /// 灰显标注「仅手动 OCR」，等真机取样确认其无障碍树形态后再评估 OCR 能力
  /// 面适配器（WeChatOcrAdapter 的「空树」前提是多台真机交叉验证过的）。
  static const Map<String, String> _knownApps = {
    'com.tencent.mobileqq': 'QQ',
    'com.tencent.tim': 'TIM',
    'org.telegram.messenger': 'Telegram',
    'com.whatsapp': 'WhatsApp',
    'com.tencent.mm': '微信（OCR 兜底）',
  };

  /// 无适配器、自动采集不生效的 App（#22 复查）：chip 灰显不可勾选、永不进
  /// [_packages]——只有采集页的手动 OCR 图标可用（manualOcr 不查适配器）。
  static const Map<String, String> _manualOcrOnlyApps = {
    'com.ss.android.ugc.aweme': '抖音（仅手动 OCR）',
  };

  final Set<String> _packages = {
    'com.tencent.mobileqq',
    'org.telegram.messenger',
    'com.whatsapp',
  };

  @override
  void initState() {
    super.initState();
    // fix(#11 P0-3)：应用生命周期观察——从系统设置（无障碍/通知/悬浮窗）授权
    // 回来时 didChangeAppLifecycleState(resumed) 触发刷新。
    WidgetsBinding.instance.addObserver(this);
    _session = CaptureSession(
      config: widget.config,
      relationship: widget.relationship,
      overlayEnabled: widget.overlayEnabled,
      // B8：展示模式跟随设置页同一份 notifier，推悬浮窗时透传给原生侧。
      displayMode: widget.displayMode,
      // fix(#11 P0-N) 独立复核补接：场景 notifier 透传给会话——采集流此前
      // 漏接（resolveScenario 每轮拿到 null，引导页选的场景对 Android 采集
      // 零效果）。同一份 notifier 每轮现读，场景切换下一轮起草立即生效。
      scenarioId: widget.scenarioId,
      // C10：检查点经闸门句柄写入（见 [_gatedWriteCheckpoint]——恢复提示未决
      // 期间拦下，防止进页期的空写入覆盖存档里的上次会话）。
      writeCheckpoint: _gatedWriteCheckpoint,
      // C9：统计实例随构造注入（C9 接线契约，usage_stats.dart）。
      stats: widget.usage,
      // G7：偏好档案注入——每轮把 styleAddendum 附言随 ctx 进写作路。
      preferences: widget.preferences,
    );
    // 会话状态（快照/分析/忙碌/错误）与改写中的卡片集合变化时重绘：stream 回调
    // 不经过 setState，不监听的话「实时快照与建议」永远停在首次 build。
    _session.state.addListener(_onStateChanged);
    _session.refiningCards.addListener(_onStateChanged);
    // #3 遗留 low：showSuggestions 返回 false → 权限引导 SnackBar + 开关打回关。
    _session.overlayPermissionLost.addListener(_onOverlayPermissionLost);
    // B8 展示模式在设置页被改时同步重绘（与设置页共用同一份 notifier）。
    widget.displayMode?.addListener(_onStateChanged);
    // #6 联系人（A 的 ContactStore）：激活联系人变化（选择面板切换/新建即
    // 激活/停用）→ 同步进会话（applyContact 把 relationship/persona/avoidWords
    // 组进下一轮 ChatContext）。null = 停用，与基线逐字节一致。确认入库等
    // 档案内容变化由 A 的 update() 同步刷新 activeContact，走同一监听。
    final contacts = widget.contactStore;
    if (contacts != null) {
      contacts.activeContact.addListener(_onContactChanged);
      // 进页即把当前激活联系人交给会话（与选择面板里的切换同一条路径）。
      _session.applyContact(contacts.activeContact.value);
    }
    _session.start();
    _relationship = TextEditingController(text: widget.relationship.value);
    _relationship.addListener(() {
      widget.relationship.value = _relationship.text;
    });
    // C10：恢复提示要等首帧之后再弹（对话框需要 Overlay 上下文）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerSessionRestore());
    _refreshServiceStatus();
    // fix(#11 P0-3)：通知权限现状进页查一次（resumed/didPopNext 再刷新）。
    _refreshNotificationStatus();
    // fix(kimi-review #2)：本页 initState 的 _pushConfigure 在服务未连时打空
    // （通道在而服务侧 handler 未挂，MissingPluginException 被 catch 吞掉）。
    // 「先开采集页、后启无障碍」是最常见启用路径——服务晚连后原生经 control
    // 通道发 requestConfigure（attachEngineChannels 汇聚点），这里接住并幂等
    // 重发当前配置。回调为页级：退出页清空，避免悬引用到已 dispose 的状态；
    // 页面不在时请求被丢弃，下次进页 initState 重新下发。
    CaptureAndroid.onConfigureReplay = _pushConfigure;
    _pushConfigure();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // fix(#11 P0-3)：RouteAware 订阅。本页由 main.dart 以 MaterialPageRoute
    // 推入，ModalRoute.of 不会为 null；直接 pump 本页（无路由壳）时是 null，
    // 此时跳过订阅——刷新退回 lifecycle 一条腿，不崩。observer 未注册进
    // navigatorObservers 时订阅同样惰性无害（见 [CapturePage.routeObserver]）。
    final route = ModalRoute.of<void>(context);
    if (route != null) {
      CapturePage.routeObserver.subscribe(this, route);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // fix(#11 P0-3)：从系统设置授完权回来（无障碍/悬浮窗/通知，都是跳系统
    // 页面的往返）应用 paused→resumed，此时服务可能刚连上、权限刚授予——
    // 立即刷新状态并幂等重放 configure。与引导页（onboarding_page.dart）的
    // resumed 刷新同一模式。
    if (state == AppLifecycleState.resumed) {
      _refreshAfterPermissionRoundTrip();
    }
  }

  @override
  void didPopNext() {
    // fix(#11 P0-3)：本页之上的应用内路由（对话框/底部面板/页面）pop 回来时
    // 刷新。前提是 [CapturePage.routeObserver] 注册进了 MaterialApp 的
    // navigatorObservers；未注册时本方法不会被调用（订阅惰性，无副作用）。
    _refreshAfterPermissionRoundTrip();
  }

  /// fix(#11 P0-3)：授权往返后的统一刷新——先查服务现状（isRunning → 状态卡
  /// 重绘）与通知权限现状（POST_NOTIFICATIONS → 状态行重绘），再幂等重放
  /// configure（服务刚连接时把采集范围/黑名单/防截屏期望值补齐，即
  /// onConfigureReplay 同款的重放语义）。三个动作都幂等：resumed 与
  /// didPopNext 在极端时序下先后各触发一次，重放无副作用。
  void _refreshAfterPermissionRoundTrip() {
    _refreshServiceStatus();
    _refreshNotificationStatus();
    _pushConfigure();
  }

  /// C10 检查点写入闸门：恢复提示未决期间（进页 → 用户对「待确认恢复上次
  /// 会话」做出选择）拦下检查点写入。不加闸的话，进页 initState 里的
  /// applyContact（此时还没有任何快照，签名是空串）会立刻以「空会话」覆盖
  /// 存档里的上次会话，恢复提示就永远没东西可恢复。提示落定后打开，此后
  /// 快照进门/切换联系人的写入照常。
  bool _checkpointGateOpen = false;

  Future<void> _gatedWriteCheckpoint(Map<String, dynamic>? checkpoint) async {
    if (!_checkpointGateOpen) return;
    await widget.writeCheckpoint?.call(checkpoint);
  }

  void _openCheckpointGate() {
    _checkpointGateOpen = true;
  }

  /// C10：「待确认恢复上次会话」提示（恢复必须过用户确认，不静默恢复——
  /// settings_store.dart 与 capture_session.dart 的 C10 契约）。有可恢复内容
  /// 才弹；确认后回填会话上下文并清档，取消/关闭则保留存档等下次进页再问。
  Future<void> _offerSessionRestore() async {
    final raw = widget.sessionCheckpoint;
    final checkpoint = raw == null ? null : SessionCheckpoint.fromJson(raw);
    if (checkpoint == null || checkpoint.isEmpty) {
      _openCheckpointGate();
      return;
    }
    // 联系人按存档 id 解析（档案可能已删——解析不到按「无联系人」恢复，
    // 不猜测；contact_store.dart:189 的「确认后由 UI 重新 setActive」）。
    final contact = widget.contactStore?.byId(checkpoint.activeContactId);
    final contactName = contact?.displayName;
    if (!mounted) {
      _openCheckpointGate();
      return;
    }
    final restore = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('待确认恢复上次会话'),
        content: Text(
          '上次会话进行到：\n'
          '${checkpoint.relationship.trim().isEmpty ? '' : '· 关系描述：${checkpoint.relationship.trim()}\n'}'
          '${contactName != null ? '· 联系人：$contactName\n' : ''}'
          '· 快照标识：${checkpoint.signature.isEmpty ? '（无）' : checkpoint.signature}\n\n'
          '恢复只回填关系描述与联系人（聊天内容本身不落盘、无法恢复）。'
          '不恢复则保持当前状态，存档保留到下次询问。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('不恢复'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (restore == true) {
      // 输入框先回填（控制器的监听是 controller→notifier 单向，restoreCheckpoint
      // 直写 notifier 不会回流到输入框），再回填会话上下文。
      _relationship.text = checkpoint.relationship;
      if (widget.contactStore != null && checkpoint.activeContactId != null) {
        // 解析得到才激活；档案已删时保持无联系人（不猜测），关系描述照常回填。
        if (contact != null) widget.contactStore!.setActive(contact.id);
      }
      _session.restoreCheckpoint(checkpoint, contact: contact);
      // C10：确认恢复即清档——之后由新的快照/切换写新的检查点；清档失败
      // 不拦恢复（写盘失败顶多下次进页再问一次，幂等）。
      try {
        await widget.writeCheckpoint?.call(null);
      } catch (_) {}
    }
    _openCheckpointGate();
    if (mounted) setState(() {});
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  /// #6 联系人激活变化（选择面板切换 / 新建即激活 / 停用都汇到这里）：同步进
  /// 会话并重绘。null = 停用——对应 A 契约里「无激活联系人时行为与现在逐字节
  /// 一致」的那一半。
  void _onContactChanged() {
    if (!mounted) return;
    setState(() {});
    _session.applyContact(widget.contactStore?.activeContact.value);
  }

  /// G7 偏好在任何地方被改动（候选卡记录 / 偏好面板删除、清空）后的页面联动：
  /// 先落盘回调（main.dart 注入），再重绘——勾选态取自偏好档案的样例，删除后
  /// 要立即取消对应卡上的 ✓。
  void _onPreferencesMutated() {
    widget.persistPreferences?.call();
    if (mounted) setState(() {});
  }

  /// 消费权限丢失通知：弹权限引导 SnackBar（session 已把开关打回关，这里
  /// 顺手重绘开关状态），并把通知清回 null——监听再触发时直接跳过。
  void _onOverlayPermissionLost() {
    final message = _session.overlayPermissionLost.value;
    if (!mounted || message == null) return;
    _session.overlayPermissionLost.value = null;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: '去设置',
          onPressed: () async {
            // fix(#11 P0-1 配套)：跳系统悬浮窗设置失败不再静默——失败时上一条
            // 「权限丢失」提示已消失，无反馈会把用户晾在原地。
            final actionMessenger = ScaffoldMessenger.of(context);
            try {
              await CaptureAndroid().openOverlaySettings();
            } catch (e) {
              if (!mounted) return;
              actionMessenger
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(
                  content: Text(_channelFailureText('打开悬浮窗设置', e)),
                ));
            }
          },
        ),
      ));
    setState(() {});
  }

  @override
  void dispose() {
    // fix(kimi-review #2)：重放回调随页销毁——同身份才清（防误清后来者）。
    if (CaptureAndroid.onConfigureReplay == _pushConfigure) {
      CaptureAndroid.onConfigureReplay = null;
    }
    // fix(#11 P0-3)：生命周期与路由观察随页销毁（防悬引用到已 dispose 的
    // State——RouteObserver 的订阅表不随路由 dispose 清空）。
    WidgetsBinding.instance.removeObserver(this);
    CapturePage.routeObserver.unsubscribe(this);
    _session.state.removeListener(_onStateChanged);
    _session.refiningCards.removeListener(_onStateChanged);
    _session.overlayPermissionLost.removeListener(_onOverlayPermissionLost);
    widget.displayMode?.removeListener(_onStateChanged);
    widget.contactStore?.activeContact.removeListener(_onContactChanged);
    _session.dispose();
    _relationship.dispose();
    _extra.dispose();
    _blockedInput.dispose();
    super.dispose();
  }

  Future<void> _refreshServiceStatus() async {
    try {
      final running = await CaptureAndroid().isRunning();
      if (mounted) setState(() => _serviceRunning = running);
    } catch (_) {
      // Windows 上打开本页会走到这里（通道不存在）；页面本身只在 Android 入口出现。
      if (mounted) setState(() => _serviceRunning = false);
    }
  }

  /// fix(#11 P0-3)：查通知权限现状（POST_NOTIFICATIONS）。通道不可用落
  /// 「未知」（null），与引导页 `_refreshPermissionStatus` 的容错同一口径，
  /// 不拦页面其余功能。
  Future<void> _refreshNotificationStatus() async {
    try {
      final enabled = await CaptureAndroid().canRequestNotifications();
      if (mounted) setState(() => _notificationsOn = enabled);
    } catch (_) {
      if (mounted) setState(() => _notificationsOn = null);
    }
  }

  /// fix(#11 P0-1 配套)：通道调用失败的用户可见文案。MissingPluginException =
  /// 通道无实现（Windows 调试 / 引擎未挂接 / 采集服务未连接且无插件级兜底
  /// handler）——口径统一为「采集插件未就绪」；其余错误原样展示
  /// （PlatformException 的 code/message 是排查关键），不给失败套外壳。
  String _channelFailureText(String action, Object error) {
    if (error is MissingPluginException) {
      return '$action失败：采集插件未就绪（平台通道不存在），请重装/重启应用后重试。';
    }
    return '$action失败：$error';
  }

  /// [reportFailure] = 用户动作触发的下发（OCR 兜底开关 / 芯片勾选 / 黑名单
  /// 增删，见调用点）在失败时给 SnackBar，首次运行不再无反馈。进页
  /// initState 与 onConfigureReplay 重放两条保持静默：「先开采集页、后启
  /// 无障碍」时服务未连是预期路径、由重放机制补齐（见 initState 注释），
  /// 报告会把最常见的首启路径变成每次进页的噪音——服务现状由状态卡以
  /// isRunning 回显，失败场景用户看得见。
  Future<void> _pushConfigure({bool reportFailure = false}) async {
    try {
      await CaptureAndroid().configure(
        packages: _packages,
        ocrFallback: _ocrFallback,
        blocked: _effectiveBlocked,
        // fix(#9 K-2)：防截屏期望值随 configure 载荷走——本方法同时是服务重连
        // 重放（onConfigureReplay）的落点，服务重启后原生 FLAG_SECURE 由这次
        // 幂等重发自动恢复，不再依赖用户重进页面/重拨开关。
        secure: _overlaySecure,
      );
    } catch (e) {
      // fix(#11 P0-1 配套)：用户动作的下发失败不再静默——状态行之外补一条
      // 明确原因（区分插件未就绪与其他错误）。
      if (!reportFailure || !mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(_channelFailureText('采集配置下发', e)),
        ));
    }
  }

  Future<void> _refill(String text) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _session.refill(text);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(ok ? '已填入输入框（未发送）' : '没找到可写的输入框；文本已复制到剪贴板'),
      ));
  }

  /// ④ 快速改写：会话原位替换该卡文本（busy 只作用该卡）。失败才提示——
  /// 成功时卡片文字原地更新，不必再打扰。
  Future<void> _refine(int index, String instruction) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _session.refineCandidate(index, instruction);
    if (!mounted || ok) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('改写失败，保留原文')));
  }

  /// 悬浮窗开关：打开前先查 SYSTEM_ALERT_WINDOW。这是特殊权限，没有运行时
  /// 对话框，只能引导用户去系统设置页（canDrawOverlays →
  /// ACTION_MANAGE_OVERLAY_PERMISSION）；授权回来后用户再打开一次。
  Future<void> _toggleOverlay(bool v) async {
    final messenger = ScaffoldMessenger.of(context);
    if (v) {
      var granted = false;
      try {
        granted = await CaptureAndroid().canDrawOverlays();
      } catch (e) {
        // fix(#11 P0-1 配套)：查不到授权状态就无从引导（旧实现把通道错误当
        // 「未授权」继续走系统设置分支，真实失败被吞）——明说失败原因，开关
        // 保持关。
        if (!mounted) return;
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(_channelFailureText('悬浮窗权限检查', e)),
          ));
        return;
      }
      if (!granted) {
        try {
          await CaptureAndroid().openOverlaySettings();
        } catch (e) {
          // fix(#11 P0-1 配套)：跳设置页失败不再静默（旧实现吞掉后仍弹
          // 「请在系统设置里允许…」，但页面根本没跳——用户白跑一趟）。
          if (!mounted) return;
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
              content: Text(_channelFailureText('打开悬浮窗设置', e)),
            ));
          return;
        }
        if (!mounted) return;
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('请在系统设置里允许「显示在其他应用上层」，返回后重新打开悬浮窗'),
          ));
        return; // 权限未给：开关保持关
      }
    }
    if (!mounted) return;
    // 关闭时由 session 负责立即收起悬浮窗（见 _onOverlayEnabledChanged）。
    widget.overlayEnabled.value = v;
    setState(() {});
  }

  /// fix(#11 P0-3)：通知权限请求入口。未开启时原生侧跳系统「应用通知设置」
  /// 页；授权回来（应用 paused→resumed）由 [_refreshAfterPermissionRoundTrip]
  /// 重查并更新状态行——与悬浮窗权限的引导模式一致。返回 true = 已开启
  /// （无需跳转，多见于其他入口刚授完的竞态），就地更新状态行。
  Future<void> _openNotificationSettings() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final enabled = await CaptureAndroid().requestNotifications();
      if (!mounted) return;
      if (enabled) {
        setState(() => _notificationsOn = true);
        return;
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('请在系统设置里允许本应用的通知；保活通知（含快捷动作）'
              '在 Android 13+ 未授权时会被系统隐藏。返回后自动刷新状态。'),
        ));
    } catch (e) {
      // fix(#11 P0-1 配套)：跳转失败不再静默（与同页其他权限入口同一口径）。
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(_channelFailureText('打开通知设置', e)),
        ));
    }
  }

  /// fix(#11 P0-3)：通知权限状态行（Android 13+ POST_NOTIFICATIONS 运行时
  /// 授权）。保活前台通知（KeepAliveService 的「唤出助手/重新生成」动作按钮）
  /// 在 13+ 未授权时被系统整条隐藏——服务照跑，用户失去快捷动作，所以单独
  /// 给一行状态与请求入口。null（通道不可用）显示「未知」，不给请求入口
  /// （不知道现状就没有可请求的目标）；已开启同样只读不设按钮。
  Widget _notificationCard(ColorScheme scheme) => Card(
        child: ListTile(
          leading: Icon(
            _notificationsOn == false
                ? Icons.notifications_off
                : Icons.notifications,
            color: _notificationsOn == false ? scheme.error : scheme.primary,
          ),
          title: const Text('通知'),
          subtitle: Text(_notificationsOn == null
              ? '权限状态未知（通道不可用）。Android 13+ 未授权通知时，保活通知会被系统隐藏。'
              : _notificationsOn == true
                  ? '已开启——保活通知（含快捷动作）正常显示。'
                  : '未开启——Android 13+ 上保活通知会被系统整条隐藏。'),
          trailing: _notificationsOn == false
              ? TextButton(
                  onPressed: _openNotificationSettings,
                  child: const Text('去开启'),
                )
              : null,
        ),
      );

  Widget _overlayCard() => Card(
        child: SwitchListTile(
          value: widget.overlayEnabled.value,
          onChanged: (v) => _toggleOverlay(v),
          title: const Text('悬浮窗'),
          subtitle: const Text('有新候选时在聊天应用上方弹出；需要「显示在其他应用上层」权限。'),
        ),
      );

  /// #11 防截屏开关：经 [CaptureAndroid.setSecure] 推给原生（control 通道
  /// 'setSecure'，参数 bool，Kotlin 侧落在悬浮窗窗口的 WindowManager flag）。
  /// 控制通道由采集服务注册——服务未连接（或无引擎通道）时这里抛异常：
  /// 开关保持原位并提示，不静默，也不写本地状态。
  ///
  /// fix(#9 K-2) 早退判定：原来 `if (v == _overlaySecure) return` 拿陈旧的
  /// 本地字段当事实——服务重启后原生已回默认关而页面保活（tab 不重建）时，
  /// 本地仍显示「开」，与实际相反且无法经本方法重新下发。改为比较「期望值
  /// [v] vs 服务回读值（[CaptureAndroid.isSecure]）」：不一致才下发 setSecure；
  /// 一致但本地字段陈旧时只就地同步回读值（服务已是期望状态，无需下发）。
  /// 回读本身失败（服务未连接）与下发失败同一条提示路径。
  Future<void> _toggleOverlaySecure(bool v) async {
    final messenger = ScaffoldMessenger.of(context);
    final bool serviceValue;
    try {
      serviceValue = await CaptureAndroid().isSecure();
    } catch (_) {
      // 读不回也就改不了（同一条 control 通道）：与下发失败同一提示。
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('采集服务未连接，暂时改不了悬浮窗防截屏；启用采集服务后再试。'),
        ));
      return;
    }
    if (v == serviceValue) {
      // 服务已是期望值：不下发；本地字段若是陈旧的（服务重启后的漂移）就地
      // 同步为回读值，开关显示从此与实际一致。
      if (mounted && v != _overlaySecure) setState(() => _overlaySecure = v);
      return;
    }
    try {
      await CaptureAndroid().setSecure(v);
    } catch (_) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('采集服务未连接，暂时改不了悬浮窗防截屏；启用采集服务后再试。'),
        ));
      return;
    }
    if (!mounted) return;
    setState(() => _overlaySecure = v);
  }

  /// #11 悬浮窗防截屏卡（FLAG_SECURE）——采集页的隐私开关：悬浮窗候选是
  /// 第三方对话明文，录屏可整段带走；开启后系统截图与屏幕录制都拍不到悬浮
  /// 窗内容。文案如实写明代价与限制：FLAG_SECURE 只标记悬浮窗自身窗口，
  /// 本应用的整屏 OCR（截的是别的应用/整屏）在部分机型上也可能因此拿不到
  /// 画面——「OCR 前自动临时关闭 FLAG_SECURE 再恢复」的路径涉及采集服务侧
  /// （CaptureService/ScreenCapture），先只做开关 + 文案说明限制。
  Widget _overlaySecureCard() => Card(
        child: SwitchListTile(
          value: _overlaySecure,
          onChanged: (v) => _toggleOverlaySecure(v),
          title: const Text('悬浮窗防截屏（FLAG_SECURE）'),
          subtitle: const Text(
              '开启后，系统截图与屏幕录制都拍不到悬浮窗里的候选内容——第三方对话明文不再随录屏外泄。'
              '代价：整屏识别（OCR）在部分机型上也可能因此拿不到画面，识别失败时请先临时关闭本开关再试。'),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('采集助手'),
        actions: [
          // G7「查看我的偏好」入口：列出全部已记录的反馈并支持删除——
          // 用户可查可改可删是硬约束（p0-plan G7）。
          if (widget.preferences != null)
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: '查看我的偏好',
              onPressed: () => showPreferencesSheet(
                context,
                widget.preferences!,
                onMutated: _onPreferencesMutated,
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _serviceCard(scheme),
          const SizedBox(height: 8),
          _overlayCard(),
          const SizedBox(height: 8),
          // #11 防截屏开关：跟在悬浮窗开关后面，管理的就是悬浮窗这扇窗。
          _overlaySecureCard(),
          const SizedBox(height: 8),
          // fix(#11 P0-3)：通知权限状态行（Android 13+ 运行时授权）——保活
          // 前台通知未授权时被系统隐藏，给状态与请求入口。
          _notificationCard(scheme),
          const SizedBox(height: 8),
          _scopeCard(),
          const SizedBox(height: 8),
          // #6 联系人入口：选择/新建联系人；卡上把「进提示词的正文」与
          // 「仅浏览信息」两个区明确分开标注（核心原则④）。
          if (widget.contactStore != null) ...[
            ContactSection(store: widget.contactStore!),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: _relationship,
            decoration: const InputDecoration(
              labelText: '与对方的关系（进提示词）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          // ③ 上下文补充：一句话背景，随判断与起草一起发送；清空即移除。
          TextField(
            controller: _extra,
            onChanged: (v) => _session.extraContext = v,
            decoration: const InputDecoration(
              labelText: '补充背景（如：今天是她生日）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          // A3「学习我的说话方式」：从本会话我方消息挑风格样本，只进写作路。
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _styleLearning,
            onChanged: (v) => setState(() {
              _styleLearning = v;
              _session.styleLearning = v;
            }),
            title: const Text('学习我的说话方式'),
            subtitle: const Text('从本会话「我」发出的消息里挑几条作为风格样本，随起草发送（只进写作路）。'),
          ),
          const SizedBox(height: 8),
          _snapshotCard(),
          // G1 隐私预览（kimi-review #16 抽成共用 widget，桌面流同一条）：
          // 折叠面板，展开看本轮判断/写作两条调用各自会收到什么；没有轮次
          // 时不显示。
          SendPreviewTile(preview: _session.state.value.preview),
          // G8「确认后入库」的 UI 侧：模型猜测的候选事实先停在 A 的暂存区，
          // 用户确认才写进联系人资料（共享组件，桌面流同一条）。
          if (widget.contactStore != null)
            StagedFactBar(store: widget.contactStore!),
          const SizedBox(height: 8),
          _suggestionsSection(scheme),
        ],
      ),
    );
  }

  Widget _serviceCard(ColorScheme scheme) => Card(
        child: ListTile(
          leading: Icon(
            _serviceRunning ? Icons.sensors : Icons.sensors_off,
            color: _serviceRunning ? scheme.primary : scheme.error,
          ),
          title: Text(_serviceRunning ? '采集服务运行中' : '采集服务未启用'),
          subtitle: const Text('需要无障碍权限读取聊天窗口内容；不会自动发送任何消息。'),
          trailing: TextButton(
            onPressed: () async {
              // fix(#11 P0-1 配套)：跳系统设置失败不再静默——首次运行用户点
              // 「去启用」没反应，多半是这条 catch 吞的。
              final messenger = ScaffoldMessenger.of(context);
              try {
                await CaptureAndroid().openAccessibilitySettings();
              } catch (e) {
                if (!mounted) return;
                messenger
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                    content: Text(_channelFailureText('打开无障碍设置', e)),
                  ));
              }
            },
            child: const Text('去启用'),
          ),
        ),
      );

  Widget _scopeCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                      child: Text('采集范围',
                          style: Theme.of(context).textTheme.titleSmall)),
                  const Text('OCR 兜底'),
                  Switch(
                    value: _ocrFallback,
                    onChanged: (v) {
                      setState(() => _ocrFallback = v);
                      // fix(#11 P0-1 配套)：用户动作，下发失败要可见。
                      _pushConfigure(reportFailure: true);
                    },
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                children: [
                  // fix(kimi-review #22 复查)：只有进了 Kotlin 侧 ChatApps 注册表
                  // 的包才可勾选自动采集；未适配的（抖音）灰显标注「仅手动
                  // OCR」——勾了也不会生效的承诺不给用户。
                  for (final entry in _knownApps.entries)
                    FilterChip(
                      label: Text(entry.value),
                      selected: _packages.contains(entry.key),
                      onSelected: (sel) {
                        setState(() {
                          if (sel) {
                            _packages.add(entry.key);
                          } else {
                            _packages.remove(entry.key);
                          }
                        });
                        // fix(#11 P0-1 配套)：用户动作，下发失败要可见。
                        _pushConfigure(reportFailure: true);
                      },
                    ),
                  for (final entry in _manualOcrOnlyApps.entries)
                    FilterChip(
                      label: Text(entry.value),
                      selected: false,
                      onSelected: null, // 灰显：无适配器，自动采集不生效
                    ),
                ],
              ),
              // ⑦ 采集应用黑名单区：名单内的包即使加进白名单也不采（隐私
              // 底线清单，黑名单优先于白名单由 Kotlin 侧 isBlocked() 保证）。
              // 已存项渲染为 FilterChip，点按即移除；底部输入框添加新包名。
              // 「com.android.bank 前缀命中即拦」的底线规则不进这份可编辑
              // 集合（硬编码在 Kotlin 侧），UI 上看不到也不可清空。
              const SizedBox(height: 12),
              Text('黑名单（点按标签移除）',
                  style: Theme.of(context).textTheme.titleSmall),
              Text(
                '名单内的应用永远不采集，即使它在上面被勾选（隐私底线）。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                children: [
                  for (final pkg in _effectiveBlocked.toList()..sort())
                    FilterChip(
                      label: Text(pkg),
                      selected: true,
                      onSelected: (_) => _commitBlocked(
                        Set.of(_effectiveBlocked)..remove(pkg),
                      ),
                    ),
                  if (_effectiveBlocked.isEmpty)
                    const Text('（空——没有应用被拉黑）',
                        style: TextStyle(color: Colors.black38, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _blockedInput,
                      onSubmitted: (_) => _addBlocked(),
                      decoration: const InputDecoration(
                        labelText: '添加包名（如 com.example.app）',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  TextButton(onPressed: _addBlocked, child: const Text('添加')),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _snapshotCard() {
    final state = _session.state.value;
    final snap = state.snapshot;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    snap == null ? '尚未捕获聊天窗口' : '当前会话：${snap.title ?? "（无标题）"}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: '手动整屏 OCR（不在适配清单的应用用这个）',
                  onPressed: _session.manualOcr,
                  icon: const Icon(Icons.document_scanner_outlined),
                ),
              ],
            ),
            if (snap != null) ...[
              // G3：来源行带置信度与原因标签（与桌面流共用
              // CaptureSession.sourceLineOf 的同一份文案）。
              Text('${CaptureSession.sourceLineOf(snap)}'
                  ' · 消息 ${snap.messages.length} 条'),
              const SizedBox(height: 4),
              for (final m in snap.messages.skip(
                  snap.messages.length > 6 ? snap.messages.length - 6 : 0))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${m.side == "me" ? "我" : (m.side == "other" ? "对方" : "发言人不明")}：${m.text}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// B8 当前模式：与设置页共用 notifier；未注入（main.dart 未传）时按产品
  /// 默认「主推一张大卡」渲染。
  bool get _primaryMode =>
      (widget.displayMode?.value ?? SettingsStore.displayModePrimary) ==
      SettingsStore.displayModePrimary;

  Widget _suggestionsSection(ColorScheme scheme) {
    final state = _session.state.value;
    if (state.error != null) {
      return Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(state.error!),
        ),
      );
    }
    if (state.busy) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(children: [
            CircularProgressIndicator(strokeWidth: 2),
            SizedBox(width: 12),
            Text('判断与起草中…')
          ]),
        ),
      );
    }
    // G3 置信度门控：来源不可靠的快照没有自动分析（session 挂在
    // needsConfirm），给「确认分析」的出口——点了才把这一屏内容发给模型。
    if (state.needsConfirm) {
      final snap = state.snapshot;
      if (snap != null) {
        final reasons = CaptureSession.uncertainReasonsOf(snap);
        return Card(
          child: ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title:
                Text(reasons.isEmpty ? '来源不可靠，确认分析？' : '来源不可靠（$reasons），确认分析？'),
            subtitle: Text(CaptureSession.sourceLineOf(snap)),
            trailing: FilledButton.tonal(
              onPressed: _session.confirmAnalyze,
              child: const Text('确认分析'),
            ),
          ),
        );
      }
    }
    final ranked = state.analysis?.rankedReplies ?? const <RankedReply>[];
    if (state.handled) {
      // B7：本轮已标记为不用回——安静的确认态，保留「反悔」的入口
      // （共用 widget，桌面流同一条；副标题两页口径不同，由页面传）。
      return HandledReplyCard(
        subtitle: '内容有更新时会自动重新分析；也可以现在重新起草。',
        onRedraft: _session.regenerate,
      );
    }
    if (ranked.isEmpty && !state.canSkipReply) {
      return const SizedBox.shrink();
    }
    // 候选区（B7 出口 + B8 主推/平铺 + 卡片动作 + G7 反馈标签 + 记住这条）
    // 抽成了共用 widget：两页只传数据与回调（kimi-review #16）。本页差异：
    // 主按钮是「回填」、标题行带「换一组」、空列表不渲染头部（空列表且无
    // canSkip 时整段已在上面 return 掉）。
    return CandidateList(
      ranked: ranked,
      primaryMode: _primaryMode,
      expandedCandidates: _expandedCandidates,
      onToggleExpand: _toggleCandidateExpansion,
      refiningIndexes: _session.refiningCards.value,
      onRefine: _refine,
      onPrimary: _refill,
      primaryLabel: '回填',
      canSkipReply: state.canSkipReply,
      onMarkHandled: _session.markHandled,
      onSwapReplies: _session.regenerate,
      contactStore: widget.contactStore,
      preferences: widget.preferences,
      onPreferencesMutated: _onPreferencesMutated,
    );
  }

  /// B8 备选卡展开/收回的切换（共用 widget 的回调）：点折叠行展开、点展开卡
  /// 的「收回」折回。集合是页面私有状态，改完 setState 重绘。
  void _toggleCandidateExpansion(int index) {
    setState(() {
      if (!_expandedCandidates.remove(index)) _expandedCandidates.add(index);
    });
  }
}

// ---------------------------------------------------------------------------
// #6 联系人 / G7 偏好的共享 UI：桌面流页（desktop_assistant_page.dart）与本页
// 共用同一份实现——两个文件同属交互写手，放在这里避免复制两份。候选卡上的
// 「记住这条」（RememberFactButton）与 G7 反馈标签行（FeedbackTagRow）随
// kimi-review #16 的候选区抽取一并搬去了 widgets/candidate_list.dart。
// ---------------------------------------------------------------------------

/// G8「确认后入库」的确认条（采集页与桌面流共用）：A 的
/// [ContactStore.stagedFacts] 是内存态暂存区——模型猜的候选事实只有用户在这
/// 里点「确认保存到联系人」才写进联系人的人设正文（confirmStagedFact），
/// 「丢弃」就地撤销（discardStagedFact）；此外没有任何写档案的通路（G8 硬约束）。
/// 暂存区不落盘（A 的设计：重启即清空），确认/丢弃也无需持久化状态。
class StagedFactBar extends StatefulWidget {
  const StagedFactBar({super.key, required this.store});

  final ContactStore store;

  @override
  State<StagedFactBar> createState() => _StagedFactBarState();
}

class _StagedFactBarState extends State<StagedFactBar> {
  @override
  void initState() {
    super.initState();
    widget.store.stagedFacts.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.store.stagedFacts.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// G8 确认：目标联系人由 A 解析（确认参数 → 候选自带 contactId → 当前激活）。
  /// 返回 null 表示解析不出目标，候选留在暂存区——提示用户先选人，不静默吞掉；
  /// 非 null 返回确认后的最新档案，SnackBar 告知写进了谁的资料。
  Future<void> _confirm(StagedCandidateFact fact) async {
    final messenger = ScaffoldMessenger.of(context);
    final saved = await widget.store.confirmStagedFact(fact);
    if (!mounted) return;
    if (saved == null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('没有可保存的联系人——先在「联系人」卡选择/新建，再确认保存。'),
        ));
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('已保存到「${saved.displayName}」的人设正文（进提示词）'),
      ));
  }

  void _discard(StagedCandidateFact fact) {
    widget.store.discardStagedFact(fact);
  }

  @override
  Widget build(BuildContext context) {
    final staged = widget.store.stagedFacts.value;
    if (staged.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.fact_check_outlined,
                    size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('待确认的事实——保存前需要你确认',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '以下来自「记住这条」的暂存（模型产出/候选原文），'
              '不确认就不会写进任何联系人资料。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final fact in staged)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(fact.text),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        FilledButton.tonal(
                          onPressed: () => _confirm(fact),
                          child: const Text('确认保存到联系人'),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () => _discard(fact),
                          child: const Text('丢弃'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// G7 反馈标签行（FeedbackTagRow）与其中文文案（feedbackTagLabel）已随
// kimi-review #16 的候选区抽取搬去 widgets/candidate_list.dart——本页
// 「查看我的偏好」面板（_PreferencesSheet）仍用它，经顶部 import 引入。

/// #6 联系人入口卡：显示当前激活联系人的 displayName 与「使用中」激活态，并把
/// 「进提示词的正文」与「仅浏览信息」两区明确分开标注（核心原则④：浏览信息
/// 永不进提示词——A 的 applyContact 映射保证 notes 不进 ChatContext，UI 在
/// 这里把边界画给用户看）。
class ContactSection extends StatefulWidget {
  const ContactSection({super.key, required this.store});

  final ContactStore store;

  @override
  State<ContactSection> createState() => _ContactSectionState();
}

class _ContactSectionState extends State<ContactSection> {
  @override
  void initState() {
    super.initState();
    widget.store.contacts.addListener(_onChange);
    // A 的 ContactStore.activeContact 是 ValueNotifier<ContactProfile?>：
    // 切换/停用/档案更新（update 换新实例）/删除都会写它，一处监听全覆盖。
    widget.store.activeContact.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.store.contacts.removeListener(_onChange);
    widget.store.activeContact.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  ContactProfile? get _active => widget.store.activeContact.value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = _active;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.person_outline, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('联系人',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                TextButton.icon(
                  onPressed: () =>
                      showContactPickerSheet(context, widget.store),
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('选择 / 新建'),
                ),
              ],
            ),
            if (active == null)
              Text(
                '未选择联系人——不向提示词注入任何联系人信息。',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else ...[
              Row(
                children: [
                  Flexible(
                    child: Text(active.displayName,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius:
                          const BorderRadius.all(Radius.circular(999)),
                    ),
                    child: Text(
                      '使用中',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onPrimaryContainer),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _contactZone(
                header: '进提示词的正文（模型会读到）',
                icon: Icons.description_outlined,
                borderColor: scheme.primary,
                rows: [
                  if (active.relationship.trim().isNotEmpty)
                    (text: '关系：${active.relationship.trim()}', onRemove: null),
                  // 人设正文逐行展示（G8 确认入库的事实按行追加，见
                  // ContactStore.confirmStagedFact）并给逐行移除入口——确认错
                  // 的事实有撤回通路，不必手改存档 JSON（可纠错性硬约束）。
                  for (final line in _personaLinesOf(active))
                    (
                      text: '人设：$line',
                      onRemove: () => _removePersonaLine(active, line),
                    ),
                  if (active.avoidWords.any((w) => w.trim().isNotEmpty))
                    (
                      text: '避谈词：${active.avoidWords.where((w) => w.trim().isNotEmpty).join('、')}',
                      onRemove: null,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _contactZone(
                header: '仅浏览信息（模型永远看不到）',
                icon: Icons.visibility_off_outlined,
                borderColor: scheme.outlineVariant,
                rows: [
                  if (active.notes.trim().isNotEmpty)
                    (text: '备注：${active.notes.trim()}', onRemove: null),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () =>
                          showEditContactDialog(context, widget.store, active),
                      child: const Text('编辑'),
                    ),
                    TextButton(
                      onPressed: () => widget.store.setActive(null),
                      child: const Text('停用该联系人'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 一块带标注的分区：进提示词的正文用主色描边，仅浏览信息用弱色描边 +
  /// 「模型永远看不到」的明示——两区的边界是画给用户看的硬约束。行可带
  /// 移除动作（[row.onRemove]），用于人设已确认事实的逐行撤回。
  Widget _contactZone({
    required String header,
    required IconData icon,
    required Color borderColor,
    required List<({String text, void Function()? onRemove})> rows,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(header, style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
          const SizedBox(height: 4),
          if (rows.isEmpty)
            Text('（空）',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))
          else
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(row.text,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    if (row.onRemove != null)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 28, minHeight: 28),
                        iconSize: 16,
                        icon: const Icon(Icons.delete_outline),
                        tooltip: '从人设移除这条',
                        onPressed: row.onRemove,
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  /// 人设正文按行拆（G8 确认入库的事实一行一条，见
  /// ContactStore.confirmStagedFact 的追加格式「persona\nfact」）。
  List<String> _personaLinesOf(ContactProfile contact) => [
        for (final line in contact.persona.split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
      ];

  /// 逐行撤回一条人设事实：删行 → update 落盘（编辑的是激活联系人时 store
  /// 会同步刷新 activeContact，会话侧经页面监听拿到新档案）。失败要显式提示，
  /// 静默会让用户以为撤回了、下一轮却还发出去。
  Future<void> _removePersonaLine(ContactProfile contact, String line) async {
    final messenger = ScaffoldMessenger.of(context);
    final lines = contact.persona.split('\n');
    final idx = lines.indexWhere((s) => s.trim() == line);
    if (idx < 0) return;
    lines.removeAt(idx);
    try {
      await widget.store.update(contact.copyWith(persona: lines.join('\n')));
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('已从人设移除：$line')));
    } catch (e) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('移除失败：$e')));
    }
  }
}

/// 选择联系人面板：点按即激活（联系人卡与提示词注入随之更新），右上角
/// 「新建」打开新建对话框，底部给「停用」出口（无激活联系人 = 不注入）。
void showContactPickerSheet(BuildContext context, ContactStore store) {
  showModalBottomSheet<void>(
    context: context,
    builder: (_) => _ContactPickerSheet(store: store),
  );
}

class _ContactPickerSheet extends StatefulWidget {
  const _ContactPickerSheet({required this.store});

  final ContactStore store;

  @override
  State<_ContactPickerSheet> createState() => _ContactPickerSheetState();
}

class _ContactPickerSheetState extends State<_ContactPickerSheet> {
  @override
  void initState() {
    super.initState();
    widget.store.contacts.addListener(_onChange);
    widget.store.activeContact.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.store.contacts.removeListener(_onChange);
    widget.store.activeContact.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// 长按删除的确认对话框：档案与其人设/避谈词一并删除、不可恢复——不可恢复
  /// 的动作必须过一道确认，不能做成一滑就没。
  Future<void> _confirmDelete(ContactProfile c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除联系人「${c.displayName}」？'),
        content: const Text('人设正文与避谈词一并删除，删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.store.remove(c.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final contacts = widget.store.contacts.value;
    final activeId = widget.store.activeContact.value?.id;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('选择联系人',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                TextButton.icon(
                  onPressed: () => showNewContactDialog(context, widget.store),
                  icon: const Icon(Icons.person_add_alt_1, size: 18),
                  label: const Text('新建联系人'),
                ),
              ],
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (contacts.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          '还没有联系人。点右上角「新建联系人」创建第一个；'
                          '不选择则不向提示词注入联系人信息。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      )
                    else
                      for (final c in contacts)
                        ListTile(
                          leading: Icon(
                            c.id == activeId
                                ? Icons.check_circle
                                : Icons.person_outline,
                            color: c.id == activeId
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                          title: Text(c.displayName),
                          subtitle: c.relationship.trim().isEmpty
                              ? null
                              : Text('关系：${c.relationship.trim()}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon:
                                    const Icon(Icons.edit_outlined, size: 20),
                                tooltip: '编辑「${c.displayName}」',
                                onPressed: () => showEditContactDialog(
                                    context, widget.store, c),
                              ),
                              if (c.id == activeId)
                                Text('使用中',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.onPrimaryContainer)),
                            ],
                          ),
                          // 长按删除（可纠错性/隐私：档案可删；删的是激活联系人
                          // 时 store 一并清空激活态，下一轮按「无联系人」跑）。
                          onLongPress: () => _confirmDelete(c),
                          onTap: () => widget.store.setActive(c.id),
                        ),
                    if (activeId != null)
                      ListTile(
                        leading: const Icon(Icons.person_off_outlined),
                        title: const Text('停用当前联系人'),
                        subtitle: const Text('不向提示词注入联系人信息。'),
                        onTap: () => widget.store.setActive(null),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      '长按某一行可删除联系人；点右侧铅笔编辑档案。人设里确认错'
                      '的事实，也可在联系人卡上逐行移除。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 新建联系人对话框：把「进提示词的正文」与「仅浏览信息」分成两个明确标注
/// 的区（核心原则④），保存即激活（调 A 的 create + setActive）。
void showNewContactDialog(BuildContext context, ContactStore store) {
  showDialog<void>(
    context: context,
    builder: (_) => _ContactFormDialog(store: store),
  );
}

/// 编辑联系人对话框：与新建同一份表单（[initial] 预填），保存调 A 的 update
/// （updatedAt 自动刷新；编辑的是激活联系人时 activeContact 同步换新实例，
/// 会话侧经监听拿到新档案）。可纠错性：联系人建错了/要补充，不再只能手改
/// 存档 JSON。
void showEditContactDialog(
  BuildContext context,
  ContactStore store,
  ContactProfile initial,
) {
  showDialog<void>(
    context: context,
    builder: (_) => _ContactFormDialog(store: store, initial: initial),
  );
}

class _ContactFormDialog extends StatefulWidget {
  const _ContactFormDialog({required this.store, this.initial});

  final ContactStore store;

  /// 非空 = 编辑模式（预填并以 update 保存）；null = 新建模式。
  final ContactProfile? initial;

  @override
  State<_ContactFormDialog> createState() => _ContactFormDialogState();
}

class _ContactFormDialogState extends State<_ContactFormDialog> {
  final _displayName = TextEditingController();
  final _aliases = TextEditingController();
  final _relationship = TextEditingController();
  final _persona = TextEditingController();
  final _avoidWords = TextEditingController();
  final _notes = TextEditingController();

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _displayName.text = initial.displayName;
      _aliases.text = initial.aliases.join('、');
      _relationship.text = initial.relationship;
      _persona.text = initial.persona;
      _avoidWords.text = initial.avoidWords.join('、');
      _notes.text = initial.notes;
    }
  }

  @override
  void dispose() {
    _displayName.dispose();
    _aliases.dispose();
    _relationship.dispose();
    _persona.dispose();
    _avoidWords.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// 逗号/顿号分隔 → 去空白去空（别名与避谈词共用）。
  List<String> _split(String text) => text
      .split(RegExp('[,，、]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> _save() async {
    final name = _displayName.text.trim();
    if (name.isEmpty) return; // 保存按钮只在称呼非空时可用，这里兜一道。
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (widget.initial == null) {
        // A 的 create 生成 id 并落盘（updatedAt 语义都在 A 侧）；写盘失败要
        // 显式告诉用户，不能静默——静默的话用户以为建好了，下一轮却没联系人。
        final profile = await widget.store.create(
          displayName: name,
          aliases: _split(_aliases.text),
          relationship: _relationship.text.trim(),
          persona: _persona.text.trim(),
          avoidWords: _split(_avoidWords.text),
          notes: _notes.text.trim(),
        );
        // 新建即激活（setActive 是 A 的切换入口；激活态不落盘，重启按 C10 的
        // 「待确认恢复」流程走）。编辑不改激活态：编辑谁就保持谁。
        widget.store.setActive(profile.id);
      } else {
        // 编辑走 A 的 update（updatedAt 自动刷新；编辑的是激活联系人时
        // activeContact 同步换新实例，会话侧经页面监听拿到新档案）。id 已被
        // 并发删除时 update 抛 StateError，原样显示为保存失败。
        await widget.store.update(widget.initial!.copyWith(
          displayName: name,
          aliases: _split(_aliases.text),
          relationship: _relationship.text.trim(),
          persona: _persona.text.trim(),
          avoidWords: _split(_avoidWords.text),
          notes: _notes.text.trim(),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('保存失败：$e')));
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final editing = widget.initial != null;
    return AlertDialog(
      title: Text(editing ? '编辑联系人' : '新建联系人'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field('称呼（必填）', _displayName, onChanged: (_) => setState(() {})),
            _field('别名（可选，逗号分隔，用于识别同一人的不同会话）', _aliases),
            const SizedBox(height: 8),
            _zoneHeader(context, '进提示词的正文（模型会读到）', Icons.description_outlined,
                scheme.primary),
            _field('关系（进提示词）', _relationship),
            _field('人设正文（进提示词，如：喜欢简洁直接的表达）', _persona, maxLines: 2),
            _field('避谈词（进提示词，逗号/顿号分隔，如：收入、病情）', _avoidWords),
            const SizedBox(height: 8),
            _zoneHeader(context, '仅浏览信息（模型永远看不到）',
                Icons.visibility_off_outlined, scheme.outlineVariant),
            _field('备注（只在本页浏览，不发给模型）', _notes, maxLines: 2),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _displayName.text.trim().isEmpty ? null : _save,
          child: Text(editing ? '保存' : '保存并使用'),
        ),
      ],
    );
  }

  Widget _zoneHeader(
      BuildContext context, String text, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Expanded(
              child: Text(text, style: Theme.of(context).textTheme.labelLarge)),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: controller,
          maxLines: maxLines,
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );
}

/// 「查看我的偏好」面板（G7 硬约束：用户可查可改可删）：列出全部六类反馈的
/// 计数与最近样例，逐类删除、一键清空；并展示将附进写作提示词的附言原文
/// （C 的 styleAddendum，只陈述统计事实）。
void showPreferencesSheet(
  BuildContext context,
  PreferenceProfile preferences, {
  void Function()? onMutated,
}) {
  showModalBottomSheet<void>(
    context: context,
    builder: (_) => _PreferencesSheet(
      preferences: preferences,
      onMutated: onMutated,
    ),
  );
}

class _PreferencesSheet extends StatefulWidget {
  const _PreferencesSheet({required this.preferences, this.onMutated});

  final PreferenceProfile preferences;

  /// 删除/清空后的联动回调（页面负责落盘 + 重绘卡上勾选态）。
  final void Function()? onMutated;

  @override
  State<_PreferencesSheet> createState() => _PreferencesSheetState();
}

class _PreferencesSheetState extends State<_PreferencesSheet> {
  void _changed() {
    widget.onMutated?.call();
    if (mounted) setState(() {});
  }

  void _clearTag(PreferenceTag tag) {
    widget.preferences.clear(tag);
    _changed();
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空全部偏好记录？'),
        content: const Text('六类反馈的计数与最近样例全部删除，删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    widget.preferences.clearAll();
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preferences = widget.preferences;
    final addendum = preferences.styleAddendum();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('我的偏好反馈',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              Text(
                '你对候选回复的结构化反馈：每类只记「次数 + 最近几条原文」，'
                '不覆盖人设与联系人资料；删除即时生效。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (final tag in PreferenceTag.values) _tagTile(tag, scheme),
              if (preferences.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '还没有记录。在候选卡下方点标签（太正式 / 太热情 / …）即可记录。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (addendum.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: scheme.primary),
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('将附进写作提示词的内容（只陈述统计事实）',
                          style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 4),
                      Text(addendum,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
              if (!preferences.isEmpty) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _clearAll,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: const Text('清空全部'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _tagTile(PreferenceTag tag, ColorScheme scheme) {
    final preferences = widget.preferences;
    final count = preferences.count(tag);
    final examples = preferences.examplesOf(tag);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        count > 0 ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 20,
        color: count > 0 ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(feedbackTagLabel(tag)),
      subtitle: examples.isEmpty
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in examples.take(2))
                  Text('· $e',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
      // 次数 + 删除按钮；未记录的类别没有可删的东西，不放按钮。
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            count > 0 ? '$count 次' : '未记录',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (count > 0)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除「${feedbackTagLabel(tag)}」的记录',
              onPressed: () => _clearTag(tag),
            ),
        ],
      ),
    );
  }
}
