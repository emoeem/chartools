import 'dart:convert';

import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'application/contact_store.dart';
import 'application/hotkey_controller.dart';
import 'application/model_presets.dart';
import 'application/settings_store.dart';
import 'ui/capture_page.dart';
import 'ui/desktop_assistant_page.dart';
import 'ui/onboarding_page.dart';

/// G7 偏好档案的存档键（shared_preferences）。C 的 PreferenceProfile 只给
/// toJson/fromJson（core 不落盘，见 preference_profile.dart 类注释），读写
/// 时机由 app 层接线——这里就是接线处：启动读盘，record/clear 之后写盘。
const String _preferenceProfileKey = 'preference_profile';

/// 启动时读偏好档案：坏档/无档降级为空档案，不打断启动（C 的 fromJson 本身
/// 容错，这里再兜一层平台通道异常）。
Future<PreferenceProfile> _loadPreferences() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_preferenceProfileKey);
    if (raw == null || raw.isEmpty) return PreferenceProfile();
    final Object? decoded = jsonDecode(raw);
    return PreferenceProfile.fromJson(
        decoded is Map<String, dynamic> ? decoded : null);
  } catch (_) {
    return PreferenceProfile();
  }
}

/// record/clear 之后写盘：失败静默——内存里的偏好仍然生效，与设置页「已生效
/// 但写盘失败」同一态度。
Future<void> _savePreferences(PreferenceProfile preferences) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _preferenceProfileKey, jsonEncode(preferences.toJson()));
  } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 启动即读存档：拿到持久化的设置再进 UI，避免先渲染默认值再跳变。
  // 读不到存档（首次启动 / JSON 损坏 / 平台通道不可用）就按默认值起。
  final store = SettingsStore();
  await store.load();
  // #6 联系人档案与 G7 偏好：同样在进 UI 前读盘。ContactStore 的持久化在
  // A 的 contact_store.dart（load 与 SettingsStore.load 同一节奏；签名以
  // A notes 为准）。两份都经构造参数注入采集页与桌面流页。
  final contactStore = ContactStore();
  await contactStore.load();
  final preferences = await _loadPreferences();
  // Windows 全局热键（Ctrl+Alt+C）启动即恢复：存档开关默认开，热键把桌面
  // 助手页切到前台（路由工厂在这里建——只有 main 持有 store/contactStore 等
  // 页面参数）。非 Windows 是空操作。控制器细节见 hotkey_controller.dart。
  if (HotkeyController.isSupported) {
    await HotkeyController.instance.startup(
      routeFactory: () => MaterialPageRoute<void>(
        settings:
            const RouteSettings(name: HotkeyController.assistantRouteName),
        builder: (_) => DesktopAssistantPage(
          config: store.config,
          displayMode: store.displayMode,
          contactStore: contactStore,
          preferences: preferences,
          // C9 接线：统计与设置页/采集流是同一份实例（usage_stats.dart 契约）。
          usage: store.usage,
          // 与下方 runApp 传的同款闭包（main() 里它不是具名变量，这里就地重建）。
          persistPreferences: () {
            _savePreferences(preferences);
          },
        ),
      ),
    );
  }
  // 未完成首次运行引导（p0-plan ②）就先落三步引导页；引导页点「完成」后
  // 自己换到场景首页。直接 pump ChartoolsApp 的测试不走这里（默认进场景首页）。
  runApp(ChartoolsApp(
    store: store,
    contactStore: contactStore,
    preferences: preferences,
    persistPreferences: () {
      _savePreferences(preferences);
    },
    startOnOnboarding: !store.onboarded.value,
  ));
}

/// 应用根：内存里持有一份设置（[SettingsStore] 的 ValueNotifier），设置页
/// 改它、连通性测试读它。启动时从 shared_preferences 加载，设置页的保存
/// 按钮写盘（见 application/settings_store.dart）；UI 与骨架阶段一致。
class ChartoolsApp extends StatelessWidget {
  const ChartoolsApp({
    super.key,
    required this.store,
    this.contactStore,
    this.preferences,
    this.persistPreferences,
    this.startOnOnboarding = false,
  });

  final SettingsStore store;

  /// #6 联系人档案（A 的 ContactStore）：可选——直接 pump 本组件的测试不传，
  /// 两页的联系人区不渲染（生产路径由 main() 注入）。
  final ContactStore? contactStore;

  /// G7 结构化偏好（C 的 PreferenceProfile）：可选，同上。
  final PreferenceProfile? preferences;

  /// G7 偏好落盘回调（main() 注入）：两页 record/clear 之后触发。
  final void Function()? persistPreferences;

  /// true：首页先落三步引导（[OnboardingPage]）。默认 false——引导门控只由
  /// 主入口在 [SettingsStore.load] 之后决定，直接 pump 本组件的测试与工具页
  /// 不受它影响。
  final bool startOnOnboarding;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chatools · 通用沟通助手',
      // 热键导航（Windows 全局热键唤起桌面助手页）：控制器需要从 app 外把
      // 页面推入栈顶，拿不到 BuildContext，只能经 navigatorKey（见
      // hotkey_controller.dart 的 _handleActivated）。非 Windows 下它闲置。
      navigatorKey: HotkeyController.instance.navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: startOnOnboarding
          ? OnboardingPage(
              store: store,
              homeBuilder: (_) => ScenarioListPage(
                store: store,
                contactStore: contactStore,
                preferences: preferences,
                persistPreferences: persistPreferences,
              ),
            )
          : ScenarioListPage(
              store: store,
              contactStore: contactStore,
              preferences: preferences,
              persistPreferences: persistPreferences,
            ),
    );
  }
}

/// 首页：内置五场景（[Scenarios.builtIns]）+ 右上角进设置。
class ScenarioListPage extends StatelessWidget {
  const ScenarioListPage({
    super.key,
    required this.store,
    this.contactStore,
    this.preferences,
    this.persistPreferences,
  });

  final SettingsStore store;

  /// #6 联系人档案与 G7 偏好：透传给两个助手入口页（构造参数注入）。
  final ContactStore? contactStore;
  final PreferenceProfile? preferences;
  final void Function()? persistPreferences;

  @override
  Widget build(BuildContext context) {
    final scenarios = Scenarios.builtIns;
    return Scaffold(
      appBar: AppBar(
        title: const Text('通用沟通助手'),
        actions: [
          // 采集助手只在 Android 出现：读屏与回填是 Android 独占能力。桌面
          // （Windows）没有采集层，入口换成「粘贴分析」——两个入口互斥
          // （if / else if），同一时刻只出现一个。
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            IconButton(
              icon: const Icon(Icons.assistant),
              tooltip: '采集助手',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CapturePage(
                    config: store.config,
                    relationship: store.relationship,
                    overlayEnabled: store.overlayEnabled,
                    // B8 候选展示模式：与设置页共享同一份 notifier（此前漏接，
                    // 展示模式被永久钉在 primary）。悬浮窗同构模式由
                    // CaptureSession 从同一份 notifier 在推候选时透传。
                    displayMode: store.displayMode,
                    // 采集应用黑名单（p0-plan ⑦）：与设置页同一份清单。
                    blockedPackages: store.blockedPackages,
                    // #6 联系人档案与 G7 结构化偏好（可查可改可删）+ 落盘回调。
                    contactStore: contactStore,
                    preferences: preferences,
                    persistPreferences: persistPreferences,
                    // C9/C10 接线：统计打点与检查点存取都是 SettingsStore 的
                    // 同一份（usage_stats.dart 契约；检查点恢复必须过确认）。
                    usage: store.usage,
                    writeCheckpoint: store.saveSessionCheckpoint,
                    sessionCheckpoint: store.sessionCheckpoint,
                  ),
                ),
              ),
            )
          else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows)
            IconButton(
              icon: const Icon(Icons.content_paste),
              tooltip: '粘贴分析',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  // 热键 popUntil 以路由名识别「页面已在栈上」；手动入口推的
                  // 路由也带上同一个名字（见 HotkeyController.assistantRouteName）。
                  settings: const RouteSettings(
                      name: HotkeyController.assistantRouteName),
                  builder: (_) => DesktopAssistantPage(
                    config: store.config,
                    // B8 候选展示模式：与设置页共享同一份 notifier（此前漏接）。
                    displayMode: store.displayMode,
                    // #6 联系人档案与 G7 结构化偏好（可查可改可删）+ 落盘回调。
                    contactStore: contactStore,
                    preferences: preferences,
                    persistPreferences: persistPreferences,
                    // C9 接线：统计与设置页/采集流是同一份实例（桌面流不经
                    // CaptureSession，单独注入）。
                    usage: store.usage,
                  ),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsPage(store: store),
              ),
            ),
          ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: scenarios.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, index) => _ScenarioCard(scenario: scenarios[index]),
      ),
    );
  }
}

/// 一张场景卡：名称 + 一句话描述 + 采集目标标签（[ScenarioTemplate.platforms]）。
class _ScenarioCard extends StatelessWidget {
  const _ScenarioCard({required this.scenario});

  final ScenarioTemplate scenario;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              scenario.name,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(scenario.description),
            if (scenario.platforms.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final platform in scenario.platforms)
                    _platformTag(platform, scheme),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _platformTag(String label, ColorScheme scheme) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: const BorderRadius.all(Radius.circular(999)),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
}

/// 设置页：[JevConfig] 五项 + 服务商预设下拉 + 关系描述 + 悬浮窗开关；保存
/// 按钮把内存改好的整包设置写盘（[SettingsStore.save]）。「连通性测试」
/// 跑一次真实的 ping 往返。
///
/// 服务商下拉（p0-plan ①）只做「起点」：选中即把预设地址回填进地址框，
/// 地址框仍可手改——下拉回显的永远是「当前地址属于哪档」，手改成自定义
/// 地址就落回「自定义」，不会锁死。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store});

  /// 设置的内存态与落盘目标。测试用的是输入框里的**当前值**——所见即所测，
  /// 不必先点保存。
  final SettingsStore store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _replyKey;
  late final TextEditingController _replyModel;
  late final TextEditingController _judgeModel;
  late final TextEditingController _style;
  late final TextEditingController _relationship;

  /// 悬浮窗开关的编辑值：进 [_save] 时才写回 [SettingsStore.overlayEnabled]。
  late bool _overlayEnabled;

  /// B8 候选展示模式的编辑值：进 [_save] 时写回 [SettingsStore.displayMode]。
  /// 取值 [SettingsStore.displayModePrimary] / [SettingsStore.displayModeAll]。
  late String _displayMode;

  bool _testing = false;
  String? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = widget.store.config.value;
    _baseUrl = TextEditingController(text: c.replyBaseUrl);
    _replyKey = TextEditingController(text: c.replyKey);
    _replyModel = TextEditingController(text: c.replyModel);
    _judgeModel = TextEditingController(text: c.judgeModel);
    _style = TextEditingController(text: c.style);
    _relationship =
        TextEditingController(text: widget.store.relationship.value);
    _overlayEnabled = widget.store.overlayEnabled.value;
    _displayMode = widget.store.displayMode.value;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _replyKey.dispose();
    _replyModel.dispose();
    _judgeModel.dispose();
    _style.dispose();
    _relationship.dispose();
    super.dispose();
  }

  /// 把输入框当前值合进现有配置（copyWith 只动这五项，judgeKey 等不丢）。
  /// base/key/model 按旧仓库 Prefs setter 的习惯 trim，style 是用户自己的
  /// 话，原样保留。copyWith 的 null 表示「不动」，所以空串也要显式传。
  JevConfig _configFromFields() => widget.store.config.value.copyWith(
        replyBaseUrl: _baseUrl.text.trim(),
        replyKey: _replyKey.text.trim(),
        replyModel: _replyModel.text.trim(),
        judgeModel: _judgeModel.text.trim(),
        style: _style.text,
      );

  Future<void> _save() async {
    widget.store.config.value = _configFromFields();
    // 关系描述按旧仓库 Prefs setter 的习惯原样保存（不 trim），修剪留给使用方。
    widget.store.relationship.value = _relationship.text;
    widget.store.overlayEnabled.value = _overlayEnabled;
    // B8 展示模式与悬浮窗开关同一节奏：保存才提交，采集页/桌面页与悬浮窗
    // 读的都是这份 notifier，下一轮渲染/下一批候选生效。
    widget.store.displayMode.value = _displayMode;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.store.save();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('已保存（重启后自动恢复）')),
        );
    } catch (e) {
      // 写盘失败不影响本次运行：内存里的新值已经生效。
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('已生效但写盘失败：$e')),
        );
    }
  }

  Future<void> _runPing() async {
    setState(() {
      _testing = true;
      _result = null;
      _error = null;
    });
    try {
      final reply = await ReplyClient(_configFromFields()).ping();
      if (!mounted) return;
      setState(() {
        _result = reply.isEmpty ? '（模型返回了空内容）' : reply;
      });
    } on ApiException catch (e) {
      // 错误文案原样显示：路由 + HTTP 状态 + 响应体前 120 字（见 ApiException）。
      if (!mounted) return;
      setState(() {
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
        });
      }
    }
  }

  /// C9 统计卡：四条路由一行一个 —— 大字是累计口径（随设置持久化），小字
  /// 是本次会话口径（启动清零）。数字在打开本页 / 点重置时读取一次：后台
  /// 采集链路的增量要重进本页才刷新（UsageStats 没有通知机制，见其读数注释）。
  Widget _usageCard() {
    final usage = widget.store.usage;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final route in UsageRoute.values) ...[
              Text(
                '${route.label}：调用 ${usage.calls(route)}'
                ' · 失败 ${usage.failures(route)}'
                ' · 缓存命中 ${usage.cacheHits(route)}',
              ),
              Text(
                '本次会话：调用 ${usage.calls(route, session: true)}'
                ' · 失败 ${usage.failures(route, session: true)}'
                ' · 缓存命中 ${usage.cacheHits(route, session: true)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _resetUsage,
                icon: const Icon(Icons.restart_alt),
                label: const Text('重置统计'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 重置统计：两个口径清零并刷新卡片，随后尽力把清零后的累计口径写盘。
  /// 统计是次要数据，写盘失败不弹打扰性提示 —— 下次保存设置时会再写一次。
  Future<void> _resetUsage() async {
    setState(() => widget.store.usage.reset());
    try {
      await widget.store.save();
    } catch (_) {
      // 写盘失败仅影响持久化：内存里已清零，下次保存设置时补写。
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('模型路由', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '配置保存到本机，重启后自动恢复。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          // 服务商预设（p0-plan ①）：选中即回填下方地址框。value 按地址框
          // 当前内容反查（ModelPresets.byBaseUrl），所以手动改地址后下拉会
          // 自己落到「自定义」——预设是起点，不锁死。key 是否已填驱动提醒行。
          ModelPresetPicker(
            value: ModelPresets.byBaseUrl(_baseUrl.text.trim()),
            hasKey: _replyKey.text.trim().isNotEmpty,
            onChanged: (preset) =>
                setState(() => _baseUrl.text = preset.replyBaseUrl),
          ),
          const SizedBox(height: 12),
          // 两个输入框 onChanged 触发重绘：让下拉回显与预设提示跟手。
          _field(
            '回复接口地址（到 /v1 为止）',
            _baseUrl,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
          ),
          _field(
            '回复接口 API Key',
            _replyKey,
            obscure: true,
            onChanged: (_) => setState(() {}),
          ),
          _field('回复模型', _replyModel),
          _field('判断模型', _judgeModel),
          _field('语气 / 人设备注', _style, maxLines: 3),
          const SizedBox(height: 8),
          Text('关系与悬浮窗', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          _field('与对方的关系（进提示词）', _relationship),
          // 悬浮窗开关与采集侧共用同一份 notifier（SettingsStore.overlayEnabled，
          // 采集流水线直接消费，见 capture_session.dart）：这里保存后立即生效。
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('悬浮窗开关'),
            subtitle: const Text('有新候选时在聊天应用上方弹出；与采集助手页的开关是同一份'),
            value: _overlayEnabled,
            onChanged: (v) => setState(() => _overlayEnabled = v),
          ),
          // B8「一条推荐+两条备选」的展示模式开关：开 = 主推排序第一张大卡、
          // 备选折叠为两行小字（默认）；关 = 全部候选平铺。候选页与悬浮窗
          // 同构读这一份值。
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('主推模式（一条推荐+备选折叠）'),
            subtitle: const Text('开：排序第一张大卡为主推，备选折叠两行小字、点击展开；关：全部候选平铺。'),
            value: _displayMode == SettingsStore.displayModePrimary,
            onChanged: (v) => setState(() => _displayMode = v
                ? SettingsStore.displayModePrimary
                : SettingsStore.displayModeAll),
          ),
          const SizedBox(height: 8),
          // C9 调用统计卡：judge/reply/review/polish 四行数字（累计 + 本次
          // 会话两个口径）+ 重置按钮。统计是用户自己的数据（p0-plan ②），
          // 可查看、可清零；清零随下次写盘持久化。
          Text('调用统计', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '累计口径随设置保存，「本次会话」自应用启动起计。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _usageCard(),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _testing ? null : _runPing,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check),
                  label: const Text('连通性测试'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_result != null)
            _resultCard(
              '模型回复',
              _result!,
              Theme.of(context).colorScheme.primaryContainer,
            ),
          if (_error != null)
            _resultCard(
              '连接失败',
              _error!,
              Theme.of(context).colorScheme.errorContainer,
            ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    bool obscure = false,
    int maxLines = 1,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          obscureText: obscure,
          maxLines: maxLines,
          keyboardType: keyboardType,
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  Widget _resultCard(String title, String text, Color background) => Card(
        color: background,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              SelectionArea(child: Text(text)),
            ],
          ),
        ),
      );
}
