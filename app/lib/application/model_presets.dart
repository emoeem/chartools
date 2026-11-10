/// 模型服务商预设（p0-plan ①）：给「回复接口」四个开箱即用的起点。
///
/// 预设只是起点、不是锁死：设置页与引导页选中一档后把
/// [ModelPreset.replyBaseUrl] 回填进地址框，用户随后仍可手改。判断路由
/// （judgeProvider/judgeBaseUrl 等）不归预设管——它只在
/// [ModelPreset.judgeProtocolHint] 里说清与本预设的关系，不做任何改写；
/// 回复密钥也由用户自己填（Ollama 档可留空）。
library;

/// 一档服务商预设：纯数据，不含逻辑与 UI。
class ModelPreset {
  const ModelPreset({
    required this.id,
    required this.name,
    required this.replyBaseUrl,
    required this.judgeProtocolHint,
    required this.needsKey,
    required this.note,
  });

  /// 蛇形命名的稳定外部键（与 Scenarios.builtIns 的 id 同一约定）：改名字
  /// 等于让已保存的选择失效。
  final String id;

  /// 下拉与引导页的展示名。
  final String name;

  /// 回复路由的 OpenAI 兼容 base（到 /v1 为止；DeepSeek 官方带不带 /v1 都收，
  /// 这里按 p0-plan 给根地址）。选中后回填进地址框。
  final String replyBaseUrl;

  /// 判断协议提示：说清判断路由与本预设的关系。预设不改判断路由的任何字段，
  /// 提示只陈述事实——需要判断侧也换服务商的用户，去设置页手动配。
  final String judgeProtocolHint;

  /// 是否需要 API Key。Ollama 本机档为 false：key 留空即可用（HTTP 层发的
  /// `Authorization: Bearer ` 空头会被它忽略，见 core http_json.dart）。
  final bool needsKey;

  /// 一句话备注：离线 / 计费等用户最关心的事。
  final String note;

  /// 选中一档后展示的提示行：备注、key 要求、判断协议，一行一条。
  /// [hasKey] 是「回复接口 Key 是否已填」，决定需要 key 的档位要不要提醒。
  List<String> hintLines({required bool hasKey}) => [
        note,
        if (needsKey && !hasKey) '需要 API Key：填在「回复接口 API Key」，也可以先用后配。',
        if (!needsKey) '无需 API Key，留空即可。',
        judgeProtocolHint,
      ];
}

/// 内置四档与查询（p0-plan ① 的 deepseek / ollama / openrouter / dashscope）。
abstract final class ModelPresets {
  /// DeepSeek 官方。判断侧若也指向 DeepSeek，core 的
  /// effectiveJudgeProtocol 对 'deepseek' 供应商自动选 chat，无需手选。
  static const ModelPreset deepseek = ModelPreset(
    id: 'deepseek',
    name: 'DeepSeek 官方',
    replyBaseUrl: 'https://api.deepseek.com',
    judgeProtocolHint: '判断路由若也指向 DeepSeek，判断协议自动用 chat，无需手选。',
    needsKey: true,
    note: 'DeepSeek 官方接口，按量计费。',
  );

  /// Ollama 本机离线档（隐私卖点）：聊天内容不出本机。
  static const ModelPreset ollama = ModelPreset(
    id: 'ollama',
    name: 'Ollama（本机）',
    replyBaseUrl: 'http://127.0.0.1:11434/v1',
    judgeProtocolHint: '本机 OpenAI 兼容接口；只改回复地址，判断路由保持当前配置不变。',
    needsKey: false,
    note: '完全离线，聊天内容不出本机。',
  );

  /// OpenRouter 聚合网关（JevConfig 里 replyBaseUrl 的出厂默认就是它）。
  static const ModelPreset openrouter = ModelPreset(
    id: 'openrouter',
    name: 'OpenRouter',
    replyBaseUrl: 'https://openrouter.ai/api/v1',
    judgeProtocolHint: 'OpenAI 兼容接口；只改回复地址，判断路由保持当前配置不变。',
    needsKey: true,
    note: '聚合多家模型，一个 Key 可切换多家，按量计费。',
  );

  /// 通义千问（阿里云 DashScope 的 OpenAI 兼容模式）。
  static const ModelPreset dashscope = ModelPreset(
    id: 'dashscope',
    name: '通义千问（DashScope 兼容模式）',
    replyBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    judgeProtocolHint: 'OpenAI 兼容接口；只改回复地址，判断路由保持当前配置不变。',
    needsKey: true,
    note: '走阿里云 DashScope 的兼容模式，按量计费。',
  );

  /// 全部内置预设，顺序即下拉顺序（p0-plan ① 的罗列顺序）。
  static const List<ModelPreset> builtIns = [
    deepseek,
    ollama,
    openrouter,
    dashscope,
  ];

  /// 按 id 查预设；未知 id（含空串）返回 null，调用方按未选择处理。
  static ModelPreset? byId(String id) {
    for (final preset in builtIns) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// 按回复地址反查预设（设置页/引导页回显「当前在用哪档」用）：
  /// 两边都 trim 并去掉尾部斜杠后比较。匹配不上（自定义地址 / 空地址）
  /// 返回 null，调用方显示「自定义」占位——预设只是起点，不据此锁地址。
  static ModelPreset? byBaseUrl(String url) {
    final normalized = _normalizeBaseUrl(url);
    for (final preset in builtIns) {
      if (_normalizeBaseUrl(preset.replyBaseUrl) == normalized) return preset;
    }
    return null;
  }

  static String _normalizeBaseUrl(String url) =>
      url.trim().replaceAll(RegExp(r'/+$'), '');
}
