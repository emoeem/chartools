import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/material.dart';

/// 判断路由配置区（P0「判断路由默认关闭 + 可配」裁定的设置面）。
///
/// 为什么是独立组件而不是整页：设置页本体在 main.dart（SettingsPage，含
/// 回复路由配置区），本文件只承载新增的「判断模型」配置区，嵌入方（main.dart
/// 的 SettingsPage）在「模型路由」区把旧的单行 `_field('判断模型', …)` 换成
/// 本组件即可，接线三步：
/// ```dart
/// import 'ui/settings_page.dart';
/// // 1. 模型路由区删除旧的单行判断模型输入框（避免与本区双写同一字段）；
/// // 2. 原位置放：JudgeRouteSection(config: store.config, onEdited: () => setState(() {}));
/// // 3. _configFromFields() 里删掉 judgeModel 一行（本区即时写 config.value，
/// //    保存按钮的 copyWith 只动回复五项，判断字段不再经它合并）。
/// ```
///
/// 交互与回复路由配置区同款（p0-plan ① 的既定样式）：服务商下拉只是「起点」
/// （InputDecorator + DropdownButton + 提示行，选中即回填、不锁死），地址 /
/// Key / 模型三个输入框照旧。判断侧在下拉之上多一条**降级状态行**：路由未
/// 配置时明说「跳过判断、直接起草」——默认关闭是产品裁定（全新安装即用，
/// onboarding 只配回复路由不动），但用户应当能看见判断此刻是关着的。
///
/// 写入节奏：本区每个字段的 onChanged **即时写 `config.value`**（copyWith
/// 只动判断四字段，回复路由与其它设置一律不碰）——与悬浮窗开关 / B8 主推
/// 模式开关同款「内存即时生效、保存按钮落盘」节奏；宿主的 [SettingsStore.save]
/// 照常把 config.value 整包写盘。落盘前退出页面：判断改动留在内存（本轮
/// 生效）但不持久化，与那两个开关的既有取舍一致。
///
/// 连通性测试：**留白**——分路由的 judge ping（与回复路 ping 并列）按裁定
/// 留到下一轮做，这里只留注释位，不放半成品按钮。
class JudgeRouteSection extends StatefulWidget {
  const JudgeRouteSection({
    super.key,
    required this.config,
    this.onEdited,
  });

  /// 判断路由字段的读写源：初始值从这里读，编辑即时写回（copyWith 只动
  /// judgeProvider/judgeBaseUrl/judgeKey/judgeModel 四项）。与采集流水线
  /// （CaptureSession.config）同一份 notifier——改动下一轮立即生效，
  /// JevClient 按 config 变更重建实例。
  final ValueNotifier<JevConfig> config;

  /// 每次写入后的宿主回调：宿主（设置页）用它触发自己的 setState，让页面上
  /// 依赖 config 的其它回显（如服务商预设提示）跟手。可空——测试直 pump
  /// 本组件时不传。
  final VoidCallback? onEdited;

  @override
  State<JudgeRouteSection> createState() => _JudgeRouteSectionState();
}

class _JudgeRouteSectionState extends State<JudgeRouteSection> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _key;
  late final TextEditingController _model;

  @override
  void initState() {
    super.initState();
    final c = widget.config.value;
    _baseUrl = TextEditingController(text: c.judgeBaseUrl);
    _key = TextEditingController(text: c.judgeKey);
    _model = TextEditingController(text: c.judgeModel);
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  /// 把一个判断字段写回 config.value（即时生效，落盘等宿主的保存按钮）。
  /// 按旧仓库 Prefs setter 的习惯 trim；copyWith 的 null 表示「不动」，
  /// 空串要显式传（「填过又清空」是合法状态）。
  void _write({String? baseUrl, String? key, String? model}) {
    widget.config.value = widget.config.value.copyWith(
      judgeBaseUrl: baseUrl,
      judgeKey: key,
      judgeModel: model,
    );
    setState(() {}); // 端点预览 / 降级状态行跟手。
    widget.onEdited?.call();
  }

  /// 下拉选项的写入：provider + protocol 一起落（chat 档需要显式协议值，
  /// 其余档清空协议回到「按 provider 推断」的既有语义）。
  void _selectProvider(_JudgeProviderOption option) {
    widget.config.value = widget.config.value.copyWith(
      judgeProvider: option.provider,
      judgeProtocol: option.protocol,
    );
    setState(() {});
    widget.onEdited?.call();
  }

  /// 当前配置回显成下拉档位；不属于任何档（bocha/typesafe/vercel/zen、
  /// custom+decisions 等高级组合）返回 null，下拉显示 hint 占位——与
  /// ModelPresetPicker「预设只是起点，不据此锁死」同一口径。
  _JudgeProviderOption? get _current {
    final c = widget.config.value;
    for (final option in _JudgeProviderOption.builtIns) {
      if (option.matches(c)) return option;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final config = widget.config.value;
    final following =
        config.judgeProvider == JevConfig.judgeProviderFollowReply;
    final option = _current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('判断模型（判断路由）', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        // P0 产品裁定写进副标题：默认关闭不是缺陷，是「开箱即用」的一部分。
        Text(
          '默认关闭：未配置时每轮跳过判断、直接起草（候选不带判断结果）。'
          '配置后判断先行，候选按局势定调。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        InputDecorator(
          decoration: const InputDecoration(
            labelText: '判断服务商',
            border: OutlineInputBorder(),
          ),
          child: DropdownButton<_JudgeProviderOption>(
            value: option,
            hint: const Text('自定义（保留当前高级配置）'),
            isExpanded: true,
            isDense: true,
            // InputDecorator 自带下划线，再去一层避免双线（与
            // ModelPresetPicker 同款）。
            underline: const SizedBox.shrink(),
            items: [
              for (final o in _JudgeProviderOption.builtIns)
                DropdownMenuItem(value: o, child: Text(o.label)),
            ],
            onChanged: (o) {
              if (o != null) _selectProvider(o);
            },
          ),
        ),
        const SizedBox(height: 8),
        if (option != null) ...[
          for (final line in option.hintLines)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                line,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
        ],
        // 降级状态行：未配置时明说本轮会跳过判断——设置页与流水线读同一份
        // 判据（judgeRouteConfigured），两边说同一件事。
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            config.judgeRouteConfigured()
                ? '当前生效端点：${config.judgeEndpoint()}'
                : '判断路由未配置：本轮将跳过判断、直接起草。'
                    '（端点无法发请求：${config.judgeEndpoint()}）',
            style: TextStyle(
              fontSize: 12,
              color: config.judgeRouteConfigured()
                  ? scheme.onSurfaceVariant
                  : scheme.error,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _field(
          '判断接口地址',
          _baseUrl,
          keyboardType: TextInputType.url,
          enabled: !following,
          helper: following ? '跟随回复路由档无需填写，随回复接口地址。' : null,
          onChanged: (v) => _write(baseUrl: v.trim()),
        ),
        _field(
          '判断接口 API Key',
          _key,
          obscure: true,
          enabled: !following,
          helper: following ? '跟随回复路由档无需填写，随回复接口 Key。' : null,
          onChanged: (v) => _write(key: v.trim()),
        ),
        _field(
          '判断模型',
          _model,
          helper: following ? '留空 = 沿用回复模型。' : null,
          onChanged: (v) => _write(model: v.trim()),
        ),
        // 连通性测试（留白）：分路由的判断 ping——与回复路「连通性测试」按钮
        // 并列的 judge 连通检查——按裁定留到下一轮（分路由测试）。放这里之前
        // 先做 JudgeClient 层的单次往返封装，避免 UI 直接摸 HttpJson。
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    bool obscure = false,
    bool enabled = true,
    TextInputType? keyboardType,
    String? helper,
    ValueChanged<String>? onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          enabled: enabled,
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            helperText: helper,
            helperMaxLines: 2,
          ),
        ),
      );
}

/// 判断服务商下拉档：纯数据（档位值 + 写入的 provider/protocol 组合 + 提示
/// 文案）。与 ModelPreset 的「起点不锁死」同一哲学——选中即写入，地址仍可
/// 手改；回显按当前配置反查（[matches]），匹配不上显示自定义占位。
class _JudgeProviderOption {
  const _JudgeProviderOption({
    required this.label,
    required this.provider,
    required this.protocol,
    required this.matches,
    required this.hintLines,
  });

  /// 下拉展示名。
  final String label;

  /// 选中后写入 judgeProvider 的值。
  final String provider;

  /// 选中后写入 judgeProtocol 的值（空串 = 清空协议，按 provider 推断）。
  final String protocol;

  /// 当前配置是否属于本档（回显反查）。
  final bool Function(JevConfig config) matches;

  /// 档位提示行：协议语义、填写要求、成本说明。
  final List<String> hintLines;

  /// 下拉档位，顺序即展示顺序。
  ///
  /// P0 裁定新增「跟随回复路由」档（默认关闭的判断路由给一条零配置开启路：
  /// 回复路由配好了，判断跟着就走）；其余三档是既有协议里最常用的形状。
  /// bocha/typesafe/vercel/zen（TypeSafe 兼容网关）与 custom+decisions 不进
  /// 下拉——它们属于高级组合，存档里已有这些值时回显自定义占位、字段照常
  /// 可编辑，不会被下拉顶掉。
  static const List<_JudgeProviderOption> builtIns = [
    _JudgeProviderOption(
      label: '跟随回复路由',
      provider: JevConfig.judgeProviderFollowReply,
      protocol: '',
      matches: _isFollowReply,
      hintLines: [
        '复用回复接口的地址、Key 与模型（openai_chat 协议），无需另填。'
            '代价：每轮分析在回复路上多一次判断调用（判断+起草两连发），'
            '时延与费用相应增加。',
      ],
    ),
    _JudgeProviderOption(
      label: 'Jev 决策协议',
      provider: 'jev',
      protocol: '',
      matches: _isJev,
      hintLines: [
        'Jev/TypeSafe 决策协议：POST {判断接口地址}/alpha/decisions，'
            '需填判断接口地址与 API Key。',
      ],
    ),
    _JudgeProviderOption(
      label: 'DeepSeek 官方（chat 协议）',
      provider: 'deepseek',
      protocol: '',
      matches: _isDeepseek,
      hintLines: [
        '判断走 chat 协议；判断接口地址留空用 DeepSeek 官方宿主，'
            '只需填 Key 与模型名。',
      ],
    ),
    _JudgeProviderOption(
      label: 'OpenAI 兼容（自定义，chat 协议）',
      provider: 'custom',
      protocol: 'chat',
      matches: _isCustomChat,
      hintLines: [
        '任意 OpenAI 兼容地址（到 /v1 为止）：'
            'POST {判断接口地址}/chat/completions。',
      ],
    ),
  ];

  static bool _isFollowReply(JevConfig c) =>
      c.judgeProvider == JevConfig.judgeProviderFollowReply;

  static bool _isJev(JevConfig c) =>
      c.judgeProvider == 'jev' && c.effectiveJudgeProtocol() == 'decisions';

  static bool _isDeepseek(JevConfig c) => c.judgeProvider == 'deepseek';

  static bool _isCustomChat(JevConfig c) =>
      c.judgeProvider == 'custom' && c.effectiveJudgeProtocol() == 'chat';
}
