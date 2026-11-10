/// 内置场景模板 —— 同一套判断/起草流水线，按使用场合换一段附加指引。
///
/// 旧仓库没有这一层（Kotlin 里 "scenario" 只出现在人设卡的字段说明里，
/// `core/kb/PersonaCard.kt:33`），是本次移植新增的概念。注入规则由调用方
/// （`ReplyPrompt`）执行，本文件只负责声明：
///
///  - [ScenarioTemplate.systemAddendum] 追加在起草 system 提示词末尾；
///  - [ScenarioTemplate.userAddendum] 插在 user 提示词最后一行
///    「请给出 N 条候选回复。」之前。
///
/// ## 附加段的书写约定
///
/// 附加段自带首尾空行：system 段以一个空行开头（system 提示词末句不带
/// 换行，靠它分段），user 段以一个空行结尾（user 提示词在「请给出」之前
/// 已经以空行收尾，靠它保持段落间隔）；拼接处不再额外加工。
///
/// 附加段只准改「怎么写」，不准改「输出什么」：起草的输出契约是
/// strategy/text 两个键的 JSON 数组，任何让模型加字段、加标记、加翻译的
/// 指令都会砸掉解析层，写新场景时同样受这条约束。
///
/// ## 默认场景零侵入
///
/// `id == 'chat_copilot'` 的两个附加段是**空串**，调用方由此保证：
/// scenario 为 null 与 scenario 为 chat_copilot 时，提示词逐字节一致。
/// 谁往这两个附加段里加了字，谁就打破了「无场景 = 无变化」的承诺。
library;

/// 一个场景 = 一对附加提示词加一份展示元数据。
class ScenarioTemplate {
  const ScenarioTemplate({
    required this.id,
    required this.name,
    required this.description,
    this.platforms = const [],
    required this.systemAddendum,
    required this.userAddendum,
  });

  /// 蛇形命名，是稳定的外部键：设置持久化、[Scenarios.byId] 查询都用它，
  /// 改名等于让已保存的配置失效。
  final String id;

  /// 设置页展示名。
  final String name;

  /// 一句话说明这个场景给谁用、改什么，设置页的副标题。
  final String description;

  /// 场景适用的采集目标（app 名）。目前只作展示与筛选提示：
  /// 采集层还没有「按前台应用自动切场景」的逻辑，选场景靠用户手选。
  final List<String> platforms;

  /// 追加在起草 system 提示词末尾的长期指引；空串 = 不改 system 提示词。
  final String systemAddendum;

  /// 插在 user 提示词末尾（「请给出 N 条候选回复。」之前）的每轮提醒；
  /// 空串 = 不改 user 提示词。
  final String userAddendum;
}

/// 内置场景的清单与查询。
abstract final class Scenarios {
  /// 全部内置场景，第一个是默认场景（chat_copilot）。
  ///
  /// 顺序就是设置页的展示顺序，「默认场景在最前」是约定的一部分；
  /// 追加新场景加在列表尾部，不要插到它前面。
  static final List<ScenarioTemplate> builtIns = [
    _chatCopilot,
    _supportAgent,
    _languageLearning,
    _liveInteraction,
    _socialA11y,
  ];

  /// 默认场景：聊天副驾。附加段为空串，提示词与没有场景功能时逐字节一致
  /// ——这是调用方做「null 等价 chat_copilot」判断的依据。
  static ScenarioTemplate get chatCopilot => _chatCopilot;

  /// 客服/销售坐席辅助。
  static ScenarioTemplate get supportAgent => _supportAgent;

  /// 外语学习陪练。
  static ScenarioTemplate get languageLearning => _languageLearning;

  /// 直播/社群互动助手。
  static ScenarioTemplate get liveInteraction => _liveInteraction;

  /// 社交辅助（无障碍）。
  static ScenarioTemplate get socialA11y => _socialA11y;

  /// 按 id 找内置场景；未知 id（含空串）返回 null，调用方退回默认场景。
  static ScenarioTemplate? byId(String id) {
    final i = builtIns.indexWhere((s) => s.id == id);
    return i < 0 ? null : builtIns[i];
  }
}

/// 默认场景：不带任何附加指引。
const ScenarioTemplate _chatCopilot = ScenarioTemplate(
  id: 'chat_copilot',
  name: '聊天副驾',
  description: '默认场景：任何即时聊天里的回复助手，不带场景附加指引。',
  platforms: [],
  systemAddendum: '',
  userAddendum: '',
);

/// 客服坐席：判来意、引条款、给可直发的答复。
const ScenarioTemplate _supportAgent = ScenarioTemplate(
  id: 'support_agent',
  name: '客服坐席辅助',
  description: '电商/售后客服与销售坐席的副驾：判读客户来意，引用知识库与售后条款，给能直接发送的答复。',
  platforms: ['千牛', '抖店', '拼多多商家版', '企业微信', '飞书'],
  systemAddendum: '\n\n【客服坐席场景】你在替一名客服或销售坐席起草发给客户的消息：'
      '对方是客户，不是朋友；候选必须是可以直接粘贴发送的答复。\n'
      '- 先按对话判断客户来意（售前咨询、查单催发货、售后纠纷、议价、投诉升级），'
      '候选的骨架跟着来意走，不要所有情况都写成一种口吻。\n'
      '- 背景与知识库里给了产品参数、价格、发货时效、售后条款的，逐字以条目为准，'
      '关键数字不许改写；知识库里没有的信息宁可写「我来帮你核实」，不许编造，'
      '也不许替坐席做条款之外的承诺——退款、补发、赔偿只给流程和时限，不拍板结果。\n'
      '- 语气纠正：客户情绪再冲也不接火——不反问、不质问、不辩解上一轮、'
      '不说「您之前没说清楚」；先认下客户遇到的具体问题，再给下一步动作。\n'
      '- 一条候选只推进一件事：答疑、安抚、要一个必要信息（订单号、截图），三选一；'
      '确实需要两个信息就写成分先后的两步。\n',
  userAddendum: '（客服场景提醒）从客户这条消息的真实诉求出发，以知识库与售后条款为依据；'
      '给得出时限就写具体时限（「今天 18 点前」，不是「尽快」），给不出就如实说需要核实。'
      '若诉求超出条款范围或拿不准，候选里至少一条是引导转人工或请坐席确认，不许硬答。\n\n',
);

/// 外语陪练：候选既是消息也是学习材料。
const ScenarioTemplate _languageLearning = ScenarioTemplate(
  id: 'language_learning',
  name: '外语学习陪练',
  description: '用外语和对方聊天时的陪练：候选既是能发出去的消息也是学习材料，跟随对方语种，控制新表达密度。',
  platforms: ['HelloTalk', 'Tandem', '微信', 'QQ', 'Telegram', 'Discord'],
  systemAddendum: '\n\n【外语陪练场景】用户正在用外语与对方聊天，'
      '你起草的候选既是能发出去的消息，也是给用户看的学习材料。\n'
      '- 语种跟随对方最近这条消息：对方用外语，候选正文就用同一门外语写，'
      '不要中途切回中文；语种拿不准就按对方最近几条的多数语种来。\n'
      '- 难度贴住用户自己的水平：从历史消息里「我：」开头的那几条判断用户的外语能力，'
      '候选不要突然拔高到用户写不出的句式；一条候选最多出现一处用户没用过的新表达，多了学不动。\n'
      '- 对方的消息里有明显语法或用词错误时，不要直接指出「你说错了」：'
      '在候选里用正确的形式自然地示范一遍就够了。\n'
      '- 候选之间拉开正式度：一条口语随意、一条更礼貌完整，让用户按关系亲疏挑选；'
      'text 只放要发送的外语原文，不要夹带中文翻译或语法讲解，输出仍然是 strategy/text 的 JSON 数组。\n',
  userAddendum: '（外语陪练提醒）用对方最后一条消息的语种作答，先把对方的意思读准再动笔；'
      '句子以能自然发出去为准，不要为了展示语法把句子写长。'
      '语气拿不准时，候选之间给出不同正式度的版本，而不是同义反复。\n\n',
);

/// 直播/社群：短口播、抓具体点、控节奏。
const ScenarioTemplate _liveInteraction = ScenarioTemplate(
  id: 'live_interaction',
  name: '直播/社群互动',
  description: '直播弹幕与社群消息的互动助手：短口播、抓具体抓手、控提问节奏，维护气氛不接火。',
  platforms: ['抖音', '快手', 'B站', '小红书', '微博', '视频号'],
  systemAddendum: '\n\n【直播/社群场景】你在替主播或群管理员回复弹幕、评论或群消息：'
      '对面是一群流动的旁观者，加上这一条具体的发言。\n'
      '- 弹幕节奏：一条候选一两行、二十字上下，口语化、能一口气念出来；'
      '不用书面语，不写成公告体。\n'
      '- 抓手要具体：接住发言里那个具体的词或事（点名、复述他的原话），'
      '一条候选只抓一个点；连着几轮都在喊「欢迎」「谢谢」就换抓手，别让客套盖过内容。\n'
      '- 一条候选最多一个问句，而且要问到具体的事；空泛的集合式提问（「大家还想听什么」）'
      '不如给两个具体选项让弹幕选。\n'
      '- 有人抬杠或带节奏：不辩论、不复述杠点，用一句轻话带过并拉回正题；'
      '回应里不出现对发弹幕的人的评价，防止把节奏带大。\n'
      '- 礼物和进场感谢简短、插在话缝里，不打断正在讲的内容；'
      '不主动喊关注、加群这类场外动作，除非知识库里明确要求。\n',
  userAddendum: '（直播/社群提醒）候选要能直接念出来：短句、口语、有具体抓手；'
      '每条最多一个问句；杠精发言不接火，一句轻话拉回正题。'
      '表情符号可以用，但一条不超过一处。\n\n',
);

/// 社交辅助（无障碍）：短句直白、温和措辞、不绕弯不玩梗。
const ScenarioTemplate _socialA11y = ScenarioTemplate(
  id: 'social_a11y',
  name: '社交辅助（无障碍）',
  description: '为打字或解读社交消息有障碍的用户起草：短句直白、温和措辞、不绕弯不玩梗，用户看得懂也认领得下来。',
  platforms: ['微信', 'QQ', '短信', 'Telegram'],
  systemAddendum: '\n\n【社交辅助场景】用户在打字或解读社交消息上有障碍'
      '（视障、输入困难或社交解读困难），你起草的候选要同时满足两边：'
      '对方读着自然，用户自己看得懂、认领得下来。\n'
      '- 温和直白：短句、常用词，一句话一个意思；不用反讽、双关、缩写和网络梗，'
      '不写需要看表情包才能接住的幽默。\n'
      '- 温和不等于绕弯：拒绝或不同意的候选要写清「不太想」「这次不行」，'
      '再给对方台阶（认可对方的用意，或给一个替代方案）；'
      '不要用「再看看吧」这类模棱两可的话搪塞，那会让用户和对方都猜。\n'
      '- 每条候选只放要发送的那句话，不附加解释或旁白，'
      '输出仍然是 strategy/text 的 JSON 数组。\n'
      '- 若本轮判断结果提示对方在生气或局势偏紧，候选只做承接与确认，'
      '不催回复、不加码；把「要不要晚点再聊」写成其中一条候选。\n',
  userAddendum: '（社交辅助提醒）短句、直白、温和：先回应对方正在说的那件事，'
      '再补用户这边的情况；不同意就写明不同意并给台阶；'
      '不用缩写、梗和反讽，让用户和对方都不用猜。\n\n',
);
