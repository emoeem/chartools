import 'package:capture_android/capture_android.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../application/model_presets.dart';
import '../application/settings_store.dart';

/// 「服务商」下拉（p0-plan ①）：引导页第二步与设置页（main.dart 的
/// SettingsPage）共用这一个实现。
///
/// 选中一档只是把 [ModelPreset.replyBaseUrl] 交给调用方回填的起点：组件不持有
/// 配置、不改 [JevConfig]。[value] 传 null 表示当前地址不属于任何预设（用户
/// 手改过 / 还没选），下拉显示「自定义」占位——不据此锁死地址。
class ModelPresetPicker extends StatelessWidget {
  const ModelPresetPicker({
    super.key,
    required this.value,
    required this.onChanged,
    required this.hasKey,
  });

  /// 当前回显的预设；null = 自定义（不套预设）。
  final ModelPreset? value;

  /// 选中回调。下拉没有「清除」项，只会回调非空预设；当前地址属于哪档由
  /// 调用方用 [ModelPresets.byBaseUrl] 反查，不靠回调传 null。
  final ValueChanged<ModelPreset> onChanged;

  /// 「回复接口 API Key」是否已填：决定需要 key 的档位要不要提醒。
  final bool hasKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InputDecorator(
          decoration: const InputDecoration(
            labelText: '服务商',
            border: OutlineInputBorder(),
          ),
          child: DropdownButton<ModelPreset>(
            value: value,
            hint: const Text('自定义（不套预设）'),
            isExpanded: true,
            isDense: true,
            // InputDecorator 自带下划线，再去一层避免双线。
            underline: const SizedBox.shrink(),
            items: [
              for (final preset in ModelPresets.builtIns)
                DropdownMenuItem(value: preset, child: Text(preset.name)),
            ],
            // DropdownButton 的回调类型带可空（ValueChanged<T?>），本组件的
            // 对外契约是非空——在这里收敛掉。
            onChanged: (preset) {
              if (preset != null) onChanged(preset);
            },
          ),
        ),
        if (value != null) ...[
          const SizedBox(height: 8),
          for (final line in value!.hintLines(hasKey: hasKey))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                line,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ],
    );
  }
}

/// 首次运行引导（p0-plan ②）：三步 PageView + 圆点指示器。
///
/// 1. 选场景：单选 [Scenarios.builtIns]，完成时写 [SettingsStore.scenarioId]；
/// 2. 选服务商预设 + 填 key（复用 [ModelPresetPicker]；可跳过 = 先用后配）；
/// 3. 平台权限引导：Android 引导开无障碍与悬浮窗权限（调既有通道）；
///    Windows 讲解粘贴分析流。
///
/// 三步的选择都先攒在本页状态里，「完成」才一次性写进 [SettingsStore] 并置
/// onboarded=true——中途杀掉应用不会留下半套配置，下次启动仍先进引导。
/// 完成后用 [OnboardingPage.homeBuilder] 替换整个首页：构造器由 main.dart
/// 注入，本文件不反向 import main.dart（那边也要 import 本文件做门控）。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    required this.store,
    required this.homeBuilder,
  });

  final SettingsStore store;

  /// 完成后的落脚页（场景首页）。
  final WidgetBuilder homeBuilder;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with WidgetsBindingObserver {
  final PageController _pageController = PageController();
  int _page = 0;

  /// 第 1 步：场景单选。初始值取已存的 scenarioId，查不到退回默认场景。
  late String _scenarioId;

  /// 第 2 步：选中的预设（null = 不套预设）与 key 输入框。
  ModelPreset? _preset;
  late final TextEditingController _key;

  /// 第 2 步是否明确跳过（先用后配）：跳过后「完成」不写预设与 key。
  bool _skipConfig = false;

  /// 第 3 步（Android）两项权限的现状：null = 未知（通道不可用 / 还没查）。
  bool? _accessibilityReady;
  bool? _overlayGranted;

  /// 「完成」防重入：落盘加换页期间再点一次不再执行。
  bool _finishing = false;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final saved = widget.store.scenarioId.value;
    _scenarioId = Scenarios.byId(saved)?.id ?? Scenarios.chatCopilot.id;
    // 回显当前路由匹配的预设：出厂默认是 OpenRouter，用户一眼能看出在哪档。
    _preset = ModelPresets.byBaseUrl(widget.store.config.value.replyBaseUrl);
    _key = TextEditingController(text: widget.store.config.value.replyKey);
    if (_isAndroid) _refreshPermissionStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置授完权回来（Android）：resumed 即刷新一次状态行。
    if (state == AppLifecycleState.resumed && _isAndroid) {
      _refreshPermissionStatus();
    }
  }

  /// 查两项 Android 权限现状：无障碍按「采集服务在跑」判断（isRunning），
  /// 悬浮窗查 SYSTEM_ALERT_WINDOW（canDrawOverlays）。通道不可用（Windows
  /// 调试 / 测试环境）一律落「未知」，引导照常可完成。
  Future<void> _refreshPermissionStatus() async {
    try {
      final running = await CaptureAndroid().isRunning();
      if (mounted) setState(() => _accessibilityReady = running);
    } catch (_) {
      if (mounted) setState(() => _accessibilityReady = null);
    }
    try {
      final granted = await CaptureAndroid().canDrawOverlays();
      if (mounted) setState(() => _overlayGranted = granted);
    } catch (_) {
      if (mounted) setState(() => _overlayGranted = null);
    }
  }

  Future<void> _openAccessibilitySettings() async {
    try {
      await CaptureAndroid().openAccessibilitySettings();
    } catch (_) {
      // 通道不可用：引导本身没有后续动作，状态行会停在「未知」。
    }
  }

  /// 悬浮窗是特殊权限、没有运行时对话框：先查再跳系统设置页（与采集页
  /// _toggleOverlay 同一策略）。这里只引导授权，不动 overlayEnabled 开关。
  Future<void> _openOverlaySettings() async {
    try {
      if (!await CaptureAndroid().canDrawOverlays()) {
        await CaptureAndroid().openOverlaySettings();
      }
    } catch (_) {
      // 同上。
    }
  }

  /// 完成：把三步攒下的选择一次性写进 [SettingsStore]，置 onboarded=true，
  /// 落盘后落到 [OnboardingPage.homeBuilder]。写盘失败不拦着进首页：内存态
  /// 已生效，只是下次启动会再看到一次引导（设置页的保存按钮可再落盘）。
  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    final messenger = ScaffoldMessenger.of(context);
    if (!_skipConfig) {
      if (_preset != null) {
        widget.store.config.value = widget.store.config.value
            .copyWith(replyBaseUrl: _preset!.replyBaseUrl);
      }
      if (_key.text.trim().isNotEmpty) {
        widget.store.config.value = widget.store.config.value
            .copyWith(replyKey: _key.text.trim());
      }
    }
    widget.store.scenarioId.value = _scenarioId;
    widget.store.onboarded.value = true;
    try {
      await widget.store.save();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('已生效但写盘失败：$e')));
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: widget.homeBuilder),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('初次设置'),
        // 引导页是根路由，没有上一页可回；也避免 Android 返回键误退。
        automaticallyImplyLeading: false,
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (index) {
                setState(() => _page = index);
                // 权限引导页进入时现查一次：离开应用半天再回来也能看到新状态。
                if (index == 2 && _isAndroid) _refreshPermissionStatus();
              },
              children: [
                _scenarioStep(),
                _presetStep(),
                _isAndroid ? _androidPermissionStep() : _desktopFlowStep(),
              ],
            ),
          ),
          _indicator(),
          _buttons(),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 第 1 步

  Widget _scenarioStep() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('你主要在什么场合用它？', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            '场景决定候选回复的口吻与策略；之后随时可换。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: _scenarioId,
            onChanged: (value) {
              if (value != null) setState(() => _scenarioId = value);
            },
            child: Column(
              children: [
                for (final scenario in Scenarios.builtIns)
                  RadioListTile<String>(
                    value: scenario.id,
                    title: Text(scenario.name),
                    subtitle: Text(scenario.description),
                  ),
              ],
            ),
          ),
        ],
      );

  // ------------------------------------------------------------- 第 2 步

  Widget _presetStep() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('选择模型服务商', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            '决定候选回复由哪个模型起草；可跳过，先用后配。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          ModelPresetPicker(
            value: _skipConfig ? null : _preset,
            hasKey: _key.text.trim().isNotEmpty,
            onChanged: (preset) => setState(() {
              _preset = preset;
              _skipConfig = false; // 重新选择即取消跳过。
            }),
          ),
          if (!_skipConfig) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              obscureText: true,
              onChanged: (_) => setState(() {}), // key 行提示要跟着变。
              decoration: const InputDecoration(
                labelText: '回复接口 API Key',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _skipConfig = !_skipConfig),
              child: Text(_skipConfig ? '重新配置' : '跳过，先用后配'),
            ),
          ),
          if (_skipConfig)
            Text(
              '已跳过：之后在「设置」里随时可以配好服务商与 Key。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      );

  // ------------------------------------------------------------- 第 3 步

  /// Android：引导开无障碍与悬浮窗权限（调既有通道，只跳系统设置页）。
  Widget _androidPermissionStep() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('打开两项权限（可跳过）', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            '这些权限决定采集助手能不能用；现在跳过，之后在采集页随时能开。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(
                _accessibilityReady == true
                    ? Icons.accessibility_new
                    : Icons.accessibility,
                color: _accessibilityReady == true
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: const Text('无障碍（读屏采集）'),
              subtitle: const Text('采集服务靠无障碍读取聊天窗口内容，只在适配清单内的应用工作。'),
              trailing: Text(_statusLabel(_accessibilityReady, '已开启', '未开启')),
              isThreeLine: true,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _openAccessibilitySettings,
              child: const Text('去开启无障碍'),
            ),
          ),
          Card(
            child: ListTile(
              leading: Icon(
                _overlayGranted == true
                    ? Icons.layers
                    : Icons.layers_clear,
                color: _overlayGranted == true
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: const Text('悬浮窗（显示在其他应用上层）'),
              subtitle: const Text('有新候选时在聊天应用上方弹出；授权后可在采集页随时关。'),
              trailing: Text(_statusLabel(_overlayGranted, '已授权', '未授权')),
              isThreeLine: true,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _openOverlaySettings,
              child: const Text('去授权悬浮窗'),
            ),
          ),
        ],
      );

  /// Windows（及其它桌面端）：讲解粘贴分析流。
  Widget _desktopFlowStep() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('在 Windows 上怎么用', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          _flowParagraph(
            '没有读屏采集：把聊天记录整段复制，打开首页右上角的「粘贴分析」粘进去即可。',
          ),
          _flowParagraph(
            '粘贴格式：每行一条消息，行首用「对方：」或「我：」标明谁说的；'
            '没有前缀的行按发言人不明处理。',
          ),
          _flowParagraph(
            '分析走与 Android 相同的判断与起草流水线，用的是上一步选的服务商；'
            '热键与原生窗口采集尚未接入。',
          ),
          _flowParagraph(
            '聊天内容只会发给你选的模型服务商；选 Ollama 本机档则完全不出本机。',
          ),
        ],
      );

  Widget _flowParagraph(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.circle, size: 6),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      );

  // ------------------------------------------------------------- 指示器与按钮

  Widget _indicator() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < 3; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: i == _page ? 20 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i == _page ? scheme.primary : scheme.outlineVariant,
                borderRadius: const BorderRadius.all(Radius.circular(999)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buttons() => Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            if (_page > 0)
              OutlinedButton(
                onPressed: () => _pageController.previousPage(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                ),
                child: const Text('上一步'),
              ),
            const Spacer(),
            FilledButton(
              onPressed: _page < 2
                  ? () => _pageController.nextPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      )
                  : _finish,
              child: Text(_page < 2 ? '下一步' : '完成'),
            ),
          ],
        ),
      );

  /// 权限状态行的文案：null（通道不可用）显示「未知」。
  String _statusLabel(bool? state, String yes, String no) =>
      state == null ? '未知' : (state ? yes : no);
}
