/// 四条模型路由（判断 / 回复 / 复查 / 润色）的全部可配置项，以及由它们推导出的
/// 端点与密钥回退规则 —— 对应旧仓库 `core/Prefs.kt` 的路由字段与 helper；
/// 润色路由是本仓库新增（p0-plan #5 候选 A4），旧仓库没有对应字段。
///
/// 旧仓库把这些字段放进 Android SharedPreferences，getter/setter 顺带做
/// trim、默认值与范围钳制；本包不碰存储，只保留「字段 + 推导规则」，持久化
/// 由 app 层经 [toJson] / [fromJson] 接走。字段全部可变：设置页就是对着
/// 同一个实例改，读完直接送进客户端构造函数。
///
/// 旧仓库的读法在注释里逐条注明了出处（`Prefs.kt:行号`），哪条规则是从
/// 哪一行行为移植的一目了然；改动推导规则前先对那条注释负责。
class JevConfig {
  JevConfig();

  // ------------------------------------------------------------- 判断路由

  /// 判断路由的服务商。旧仓库取值
  /// `"bocha" | "openrouter" | "typesafe" | "vercel" | "zen" | "custom"`
  /// 加 deepseek（Prefs.kt:81-84，旧默认 openrouter）；本移植的默认值是
  /// `'jev'`（契约决定，不在旧清单里）——它不属于任何具名分支，在
  /// [judgeEndpoint] 里与 openrouter 一样落到 else 分支（base +
  /// `/alpha/decisions`），即旧仓库默认路由走的同一条路。
  ///
  /// 另有本仓库新增档 [judgeProviderFollowReply]（「跟随回复路由」，判断路由
  /// 复用回复接口）。**默认 `'jev'` + [judgeBaseUrl] 空 = 判断路由未配置**：
  /// [judgeEndpoint] 产物是 `/alpha/decisions` 相对地址，根本发不出 POST——
  /// P0 修复（判断路由默认关闭 + 优雅降级）裁定默认关，调用方先用
  /// [judgeRouteConfigured] 判定，未配置就跳过判断直接起草。
  String judgeProvider = 'jev';

  /// 「跟随回复路由」档的服务商值（设置页判断配置区可选）：判断就挂在回复
  /// 接口上——端点复用 [replyEndpoint]（openai_chat 语义）、协议强制 chat、
  /// 密钥随 [effectiveReplyKey]、模型留空沿用 [replyModel]。代价是每轮比
  /// 判断路由独立配置时多挂在同一条路上（判断 + 起草两连发，时延累加），
  /// 由设置页副标题说明；配置项零新增负担（base/key/model 全跟回复走）。
  static const String judgeProviderFollowReply = 'follow_reply';

  /// 判断路由的主机根，路径按协议/服务商拼（见 [judgeEndpoint]）。
  /// 旧仓库 setter 里 trim（Prefs.kt:87-89），这里由调用方在写入时保证；
  /// 空串表示尚未配置，app 层负责给出真实地址。空串 + 非 chat 协议时
  /// [judgeEndpoint] 产物是**相对地址**（发不出 POST）——那不是抛错的信号，
  /// 而是「判断路由未配置」的正常态，调用方以 [judgeRouteConfigured] 判定。
  String judgeBaseUrl = '';

  /// 判断路由的密钥。旧仓库经 ApiKeyVault 加密读写（Prefs.kt:91-93），
  /// 本包只存明文字段，落盘要不要加密由 app 层决定。
  String judgeKey = '';

  String judgeModel = '';

  /// 判断路由的协议：`decisions`（Jev/TypeSafe 问题协议）或 `chat`
  /// （OpenAI 兼容的聊天模型答同一套题）。空串 = 尚未选择，按 provider
  /// 推断（[effectiveJudgeProtocol]）。旧仓库显式约定「空表示未选，什么都不
  /// 迁移、不改变既有路由」（Prefs.kt:108-110 的注释）。
  String judgeProtocol = '';

  // -------------------------------------------------------------- 回复路由

  /// OpenAI 兼容 base，包含到 `/v1` 为止。旧仓库默认
  /// `https://openrouter.ai/api/v1`（Prefs.kt:120-122 + 655 行
  /// DEFAULT_REPLY_BASE）；setter 同样 trim。
  String replyBaseUrl = 'https://openrouter.ai/api/v1';

  /// 回复路由密钥，留空回退 [judgeKey]（[effectiveReplyKey]）。
  /// 旧仓库 Prefs.kt:124-127 的注释原话：`Blank = fall back to judgeKey`。
  String replyKey = '';

  /// 起草候选回复的生成模型。旧仓库默认 `deepseek/deepseek-chat-v3.1`
  /// （Prefs.kt:130-132 + 656 行）；本移植默认空串，由 app 层给默认模型。
  String replyModel = '';

  // -------------------------------------------------------------- 复查路由

  /// S1 证据复查开关。旧仓库默认**关**：它比排序多一次模型调用，是真金白银
  /// 和延迟，让用户自己决定（Prefs.kt:195-203 的注释原话）。
  bool reviewEnabled = false;

  /// 复查路由 base。三个复查字段都留空表示沿用回复路由 —— 旧仓库把这叫
  /// 「per-operation 模型路由的最小形态：先给一条独立的路，但默认不增加
  /// 配置负担」（Prefs.kt:205-211 的注释）。
  String reviewBaseUrl = '';

  String reviewKey = '';

  String reviewModel = '';

  // -------------------------------------------------------------- 润色路由

  /// A4 润色路由（p0-plan #5 候选）：自动改写专用的第四条路由。走它的只有两
  /// 处自动整改——A2 linter 命中候选的重写与 S1 复查驳回候选的重写（见
  /// ReplyClient.rewriteOnPolishRoute）；手动 refine（候选卡按钮）继续走回复
  /// 路由，便宜的自动化改写与用户点名的精修分开记账。
  ///
  /// 与复查路由同模式：三个字段都留空表示沿用回复路由 —— 没配润色路由时
  /// 行为只是「同一条路、温度收着些的重写」，不会因为少一份配置而断。
  String polishBaseUrl = '';

  /// 润色路由密钥，留空回退回复路由的实际生效密钥（[effectivePolishKey]）。
  String polishKey = '';

  /// 自动重写用的模型，留空沿用回复模型（[effectivePolishModel]）。
  String polishModel = '';

  // ---------------------------------------------------------------- 文风

  /// 全局风格自由文本，进起草提示词的人设卡；空串用内置默认。
  /// 旧仓库 Prefs.kt:321-329 的注释：这是「用户自己的话」，比固定的策略
  /// 列表更懂这段对话要怎么聊。
  String style = '';

  // ------------------------------------------------------------- 提示词开关

  /// A1「禁令改正向示例」开关（p0-plan 人味增强包 A1）：开启时起草 system
  /// 提示词里的纯禁令改写为「正向示范 + 反例对照」结构（见
  /// ReplyPrompt.systemPrompt 的 usePositiveExamples 参数）。默认关——评测
  /// 结论出来前不切默认，A1 兼容锁测试钉住默认路径的提示词逐字节不变；
  /// 这里只是把开关从「参数永远传 false」变成「可配置、可评测、可切换」。
  bool usePositiveExamples = false;

  // -------------------------------------------------------------- 采样参数

  /// 回复语言：`follow | zh | en`，默认跟随对方（Prefs.kt:331-334 +
  /// 626 行 LANG_FOLLOW）。
  String replyLanguage = 'follow';

  /// 回复长度：`short | standard | detailed`（Prefs.kt:337-339 +
  /// 630 行 LENGTH_STANDARD）。
  String replyLength = 'standard';

  /// 采样温度。旧仓库在 getter/setter 里钳到 0.0–1.5（Prefs.kt:342-344）；
  /// 本包是纯数据类，不重复钳制，范围校验放在 app 层的设置入口。
  double replyTemperature = 0.8;

  /// token 级反重复惩罚（OpenAI 兼容字段），与消息级的 avoid 环互补。
  /// 旧仓库 Prefs.kt:346-351 的注释原话：0.0 表示**不发字段**——请求体和
  /// 加这两个参数之前逐字节一样，服务商兼容性不变；只加在生成类调用上，
  /// 摘要、台账、复查这类归纳任务需要术语重复来保持一致性，永远不带惩罚。
  /// （取值范围钳制 -2.0–2.0 同样留给 app 层，见 Prefs.kt:352-358。）
  double replyFrequencyPenalty = 0.0;

  /// 同 [replyFrequencyPenalty]：0.0 = 不进请求体（Prefs.kt:356-358）。
  double replyPresencePenalty = 0.0;

  /// 往判断与起草提示词里注入多少条更早的历史（Prefs.kt:283-286）。
  int contextHistoryCount = 30;

  // ------------------------------------------------------------- 推导规则

  /// 判断协议的实际生效值：显式选择优先，否则按 provider 推断。
  /// 逐行对应旧仓库 Prefs.kt:113-115：
  /// `judgeProtocol.ifBlank { if (judgeProvider == PROVIDER_DEEPSEEK)
  /// PROTO_CHAT else PROTO_DECISIONS }` —— ifBlank 的语义是
  /// 「非空白原样返回（含未 trim 的空白字符）」，这里保持一致。
  ///
  /// 「跟随回复路由」档（[judgeProviderFollowReply]）在显式选择**之前**短路：
  /// 它的判断就挂在回复接口上，协议恒为 chat（openai_chat 语义），用户存档里
  /// 残留的 judgeProtocol 显式值不参与——换档不应该被旧档的协议拖住。
  String effectiveJudgeProtocol() {
    if (judgeProvider == judgeProviderFollowReply) return 'chat';
    if (judgeProtocol.trim().isNotEmpty) return judgeProtocol;
    return judgeProvider == 'deepseek' ? 'chat' : 'decisions';
  }

  /// 判断路由的完整 POST 地址。路径跟**协议**走，不跟服务商走：chat 协议
  /// 的模型（DeepSeek 官方）无论怎么选都挂在 `{base}/chat/completions`，
  /// decisions 协议按服务商保留各自路径（Prefs.kt:511-534 的注释原话）。
  ///
  /// - 「跟随回复路由」档：直接复用 [replyEndpoint]——判断就挂在回复接口
  ///   上（P0 判断降级的可配项，见 [judgeProviderFollowReply]）。
  /// - chat：base 为空回退 `https://api.deepseek.com`（契约钉死的宿主根；
  ///   旧仓库用的是带 `/v1` 的 `DEEPSEEK_BASE`，Prefs.kt:522 + 657/661 行，
  ///   两者 DeepSeek 都接受）。已有完整路径的自定义地址不再追加。
  /// - decisions：bocha/typesafe/vercel/zen 四家同走 `/v1/systemone`
  ///   （后三家是 TypeSafe 兼容网关，Prefs.kt:527-530）；custom 原样返回
  ///   用户填的完整地址（Prefs.kt:531，只 trim 不拼路径）；其余（含默认
  ///   'jev' 与 openrouter）落 `{base}/alpha/decisions`（Prefs.kt:532）。
  ///
  /// ⚠️ 返回值**可能是相对地址**（如全新安装 judgeBaseUrl 空时的
  /// `/alpha/decisions`）：那是「判断路由未配置」的正常产物，不是异常——
  /// 本方法保持纯函数、不抛（旧仓库语义原样保留），发不发请求由调用方先过
  /// [judgeRouteConfigured] 决定。
  String judgeEndpoint() {
    // 「跟随回复路由」：端点即回复端点，一个字节都不另拼。
    if (judgeProvider == judgeProviderFollowReply) return replyEndpoint();
    // 旧仓库 Prefs.kt:518：trim 后去掉**所有**尾部斜杠（trimEnd('/')）。
    final base = _stripTrailingSlashes(judgeBaseUrl.trim());
    if (effectiveJudgeProtocol() == 'chat') {
      // Prefs.kt:520-522 的注释：base 清空表示字段被抹掉，此时 chat 判官
      // 就是 DeepSeek 官方——那是唯一预置这个形态的宿主。
      final host = base.isEmpty ? 'https://api.deepseek.com' : base;
      // Prefs.kt:523-524：custom 填的可能本来就是完整 URL，别的都算 base。
      return host.endsWith('/chat/completions')
          ? host
          : '$host/chat/completions';
    }
    switch (judgeProvider) {
      case 'bocha':
      case 'typesafe':
      case 'vercel':
      case 'zen':
        return '$base/v1/systemone';
      case 'custom':
        // 用户给的就是完整地址：只 trim，不追加路径、不去尾部斜杠。
        return judgeBaseUrl.trim();
      default:
        return '$base/alpha/decisions';
    }
  }

  /// 判断路由是否已配置到「可以直接发起一次 POST」的程度——P0 判断降级的
  /// **唯一判据**（capture_session 与 JudgeClient 的未配置门都调它，判据
  /// 只此一份）。
  ///
  /// 判据：[judgeEndpoint] 的产物必须是绝对 http(s) 地址（有 scheme 且有
  /// host）。落到具体配置上：
  /// - 全新安装（judgeProvider='jev'、judgeBaseUrl=''）→ 产物是
  ///   `/alpha/decisions` 相对地址 → **false**。HttpClient.openUrl 对相对
  ///   地址直接抛 ArgumentError，三次重试也是白打——这正是 P0（候选恒空）
  ///   的根因，现在在门口就拦住。
  /// - chat 协议 base 空 → 回退 DeepSeek 官方宿主（既有契约）→ 产物绝对
  ///   地址 → **true**。能否连通是另一回事：属于「已配置但调用失败」，
  ///   走 JudgeClient.judge 的既有错误返回（Analysis.error）+ 调用方降级
  ///   起草，错误不吞。
  /// - 「跟随回复路由」档 → 产物即 [replyEndpoint]：回复路由有出厂默认
  ///   base（openrouter）时恒 true；用户把回复地址也清空了则同样按未配置
  ///   降级——判断与回复同生共死，不会出现「回复没配判断却在跑」的怪态。
  /// - custom 档填了裸域名（无 scheme）→ Uri 解析无 scheme → **false**：
  ///   那种地址本来就发不出 POST，按未配置处理比让它烂在重试循环里诚实。
  ///
  /// 「已配置」≠「可用」：配错地址/密钥时本方法恒 true——那是调用失败
  /// 降级路径的事，这里不猜网络。
  bool judgeRouteConfigured() {
    final url = Uri.tryParse(judgeEndpoint());
    return url != null &&
        (url.scheme == 'http' || url.scheme == 'https') &&
        url.host.isNotEmpty;
  }

  /// 回复路由的完整 POST 地址（Prefs.kt:537 逐字对应）。
  String replyEndpoint() =>
      '${_stripTrailingSlashes(replyBaseUrl.trim())}/chat/completions';

  /// 复查路由的完整 POST 地址；base 留空沿用回复路由（Prefs.kt:505-509）。
  /// 复查走的就是一次普通的 chat/completions 调用，所以拼法与回复一致。
  String reviewEndpoint() {
    var base = reviewBaseUrl.trim();
    if (base.isEmpty) base = replyBaseUrl.trim();
    return '${_stripTrailingSlashes(base)}/chat/completions';
  }

  /// 回复密钥回退判断密钥。对应旧仓库 Prefs.kt:493-494：
  /// `replyKey.ifBlank { judgeKey }` —— 非空白原样返回（不 trim）。
  String effectiveReplyKey() =>
      replyKey.trim().isNotEmpty ? replyKey : judgeKey;

  /// 判断路由的实际生效密钥：「跟随回复路由」档判断就挂在回复接口上，密钥
  /// 随回复路由走（[effectiveReplyKey] 的既有回退链）；其余档就是 [judgeKey]
  /// 原样——与 JudgeClient 既有取值逐字节一致，非跟随档的请求字节不变。
  String effectiveJudgeKey() => judgeProvider == judgeProviderFollowReply
      ? effectiveReplyKey()
      : judgeKey;

  /// 判断路由的实际生效模型：「跟随回复路由」档 judgeModel 留空沿用回复模型
  /// （与复查/润色路由「留空沿用回复」的回退规则同模式）；其余档原样返回
  /// [judgeModel]，不引入新的回退——旧仓库没有这条规则，非跟随档的请求体
  /// 必须与移植版逐字节一致。
  String effectiveJudgeModel() {
    if (judgeProvider == judgeProviderFollowReply &&
        judgeModel.trim().isEmpty) {
      return replyModel;
    }
    return judgeModel;
  }

  /// 复查密钥依次回退到回复密钥（Prefs.kt:499-500，注释原话：
  /// 「复查路由 key，依次回退到回复路由和判断路由」）。
  String effectiveReviewKey() =>
      reviewKey.trim().isNotEmpty ? reviewKey : effectiveReplyKey();

  /// 复查用的模型：留空沿用回复模型（Prefs.kt:502-503）。
  String effectiveReviewModel() =>
      reviewModel.trim().isNotEmpty ? reviewModel : replyModel;

  /// 润色路由的完整 POST 地址；base 留空沿用回复路由（与 [reviewEndpoint]
  /// 同模式）。自动重写也是一次普通的 chat/completions 调用，拼法一致。
  String polishEndpoint() {
    var base = polishBaseUrl.trim();
    if (base.isEmpty) base = replyBaseUrl.trim();
    return '${_stripTrailingSlashes(base)}/chat/completions';
  }

  /// 润色密钥回退回复路由的实际生效密钥（与 [effectiveReviewKey] 同模式，
  /// 但不经过复查密钥——润色与复查是两条互不接力的独立路由）。
  String effectivePolishKey() =>
      polishKey.trim().isNotEmpty ? polishKey : effectiveReplyKey();

  /// 润色用的模型：留空沿用回复模型（与 [effectiveReviewModel] 同模式）。
  String effectivePolishModel() =>
      polishModel.trim().isNotEmpty ? polishModel : replyModel;

  // ---------------------------------------------------------------- JSON

  /// JSON round trip（app 侧保存设置用）。键就是字段名，全部写出：
  /// 空串与缺键在语义上有差别（「用户填过又清空」vs「从没填过」），
  /// 回读必须能还原出写入时的状态。
  Map<String, dynamic> toJson() => {
        'judgeProvider': judgeProvider,
        'judgeBaseUrl': judgeBaseUrl,
        'judgeKey': judgeKey,
        'judgeModel': judgeModel,
        'judgeProtocol': judgeProtocol,
        'replyBaseUrl': replyBaseUrl,
        'replyKey': replyKey,
        'replyModel': replyModel,
        'reviewEnabled': reviewEnabled,
        'reviewBaseUrl': reviewBaseUrl,
        'reviewKey': reviewKey,
        'reviewModel': reviewModel,
        'polishBaseUrl': polishBaseUrl,
        'polishKey': polishKey,
        'polishModel': polishModel,
        'style': style,
        'replyLanguage': replyLanguage,
        'replyLength': replyLength,
        'replyTemperature': replyTemperature,
        'replyFrequencyPenalty': replyFrequencyPenalty,
        'replyPresencePenalty': replyPresencePenalty,
        'contextHistoryCount': contextHistoryCount,
        'usePositiveExamples': usePositiveExamples,
      };

  /// 缺键一律落回字段默认值，旧版本或手改过的存档不会把配置读炸。
  /// 数值统一按 `num` 读再转：JSON 里的 `0` 会被解析成 int，
  /// 直接 `as double?` 会抛。
  ///
  /// fix(kimi-review #7)：读值全部改走 [_str] / [_num] / [_bool]。原先的
  /// `as String?` / `as num?` / `as bool?` 是裸强转，存档里**单字段**类型坏
  /// （手改 JSON、旧版本写坏）就抛 TypeError，SettingsStore.load 的外层
  /// catch 会把全部设置一起重置成默认——一个坏字段连坐整包。现在类型不符
  /// 的字段单独落回默认值，其余字段照常读回。
  factory JevConfig.fromJson(Map<String, dynamic> j) => JevConfig()
    ..judgeProvider = _str(j, 'judgeProvider', 'jev')
    ..judgeBaseUrl = _str(j, 'judgeBaseUrl', '')
    ..judgeKey = _str(j, 'judgeKey', '')
    ..judgeModel = _str(j, 'judgeModel', '')
    ..judgeProtocol = _str(j, 'judgeProtocol', '')
    ..replyBaseUrl = _str(j, 'replyBaseUrl', 'https://openrouter.ai/api/v1')
    ..replyKey = _str(j, 'replyKey', '')
    ..replyModel = _str(j, 'replyModel', '')
    ..reviewEnabled = _bool(j, 'reviewEnabled', false)
    ..reviewBaseUrl = _str(j, 'reviewBaseUrl', '')
    ..reviewKey = _str(j, 'reviewKey', '')
    ..reviewModel = _str(j, 'reviewModel', '')
    ..polishBaseUrl = _str(j, 'polishBaseUrl', '')
    ..polishKey = _str(j, 'polishKey', '')
    ..polishModel = _str(j, 'polishModel', '')
    ..style = _str(j, 'style', '')
    ..replyLanguage = _str(j, 'replyLanguage', 'follow')
    ..replyLength = _str(j, 'replyLength', 'standard')
    ..replyTemperature = _num(j, 'replyTemperature', 0.8).toDouble()
    ..replyFrequencyPenalty = _num(j, 'replyFrequencyPenalty', 0.0).toDouble()
    ..replyPresencePenalty = _num(j, 'replyPresencePenalty', 0.0).toDouble()
    ..contextHistoryCount = _num(j, 'contextHistoryCount', 30).toInt()
    ..usePositiveExamples = _bool(j, 'usePositiveExamples', false);

  /// 拷贝一份再改：设置页预览、客户端构造前的小调整都走这里，
  /// 不许直接动共享实例。null 参数表示保持原值。
  JevConfig copyWith({
    String? judgeProvider,
    String? judgeBaseUrl,
    String? judgeKey,
    String? judgeModel,
    String? judgeProtocol,
    String? replyBaseUrl,
    String? replyKey,
    String? replyModel,
    bool? reviewEnabled,
    String? reviewBaseUrl,
    String? reviewKey,
    String? reviewModel,
    String? polishBaseUrl,
    String? polishKey,
    String? polishModel,
    String? style,
    String? replyLanguage,
    String? replyLength,
    double? replyTemperature,
    double? replyFrequencyPenalty,
    double? replyPresencePenalty,
    int? contextHistoryCount,
    bool? usePositiveExamples,
  }) =>
      JevConfig()
        ..judgeProvider = judgeProvider ?? this.judgeProvider
        ..judgeBaseUrl = judgeBaseUrl ?? this.judgeBaseUrl
        ..judgeKey = judgeKey ?? this.judgeKey
        ..judgeModel = judgeModel ?? this.judgeModel
        ..judgeProtocol = judgeProtocol ?? this.judgeProtocol
        ..replyBaseUrl = replyBaseUrl ?? this.replyBaseUrl
        ..replyKey = replyKey ?? this.replyKey
        ..replyModel = replyModel ?? this.replyModel
        ..reviewEnabled = reviewEnabled ?? this.reviewEnabled
        ..reviewBaseUrl = reviewBaseUrl ?? this.reviewBaseUrl
        ..reviewKey = reviewKey ?? this.reviewKey
        ..reviewModel = reviewModel ?? this.reviewModel
        ..polishBaseUrl = polishBaseUrl ?? this.polishBaseUrl
        ..polishKey = polishKey ?? this.polishKey
        ..polishModel = polishModel ?? this.polishModel
        ..style = style ?? this.style
        ..replyLanguage = replyLanguage ?? this.replyLanguage
        ..replyLength = replyLength ?? this.replyLength
        ..replyTemperature = replyTemperature ?? this.replyTemperature
        ..replyFrequencyPenalty =
            replyFrequencyPenalty ?? this.replyFrequencyPenalty
        ..replyPresencePenalty =
            replyPresencePenalty ?? this.replyPresencePenalty
        ..contextHistoryCount = contextHistoryCount ?? this.contextHistoryCount
        ..usePositiveExamples = usePositiveExamples ?? this.usePositiveExamples;
}

/// 旧仓库 Kotlin `trimEnd('/')` 的等价物：去掉**全部**尾部斜杠。
/// Dart 没有按单字符的 trimEnd，用正则一次剥干净
/// （`https://x///` → `https://x`）。
String _stripTrailingSlashes(String s) => s.replaceAll(RegExp(r'/+$'), '');

// fix(kimi-review #7)：fromJson 的逐字段容错读取。三个 helper 都只在
// [JevConfig.fromJson] 里用：值类型与字段声明一致就原样返回，不一致（或
// 缺键 / 显式 null）就取调用方给的默认值——单字段脏不再抛 TypeError 连坐
// 整包。语义与原先「`as T? ?? 默认`」在健康存档上完全一致：null 照旧视为
// 缺省，缺键照旧落默认。

/// 读一个字符串字段，类型不符取 [fallback]。
String _str(Map<String, dynamic> j, String key, String fallback) {
  final v = j[key];
  return v is String ? v : fallback;
}

/// 读一个数值字段，类型不符取 [fallback]。JSON 的 int 与 double 都是 num，
/// 调用方按字段类型自行 toDouble / toInt。
num _num(Map<String, dynamic> j, String key, num fallback) {
  final v = j[key];
  return v is num ? v : fallback;
}

/// 读一个布尔字段，类型不符取 [fallback]。
bool _bool(Map<String, dynamic> j, String key, bool fallback) {
  final v = j[key];
  return v is bool ? v : fallback;
}
