/// 人设库的应用层：一批**有名字的人设卡**（PersonaEntry）+ Character Card V2
/// 兼容导入（导入预览 → 确认才落库）+ shared_preferences JSON 持久化。
///
/// ## 与 PersonaCard 的分工（legacy PersonaProfile.kt:17 的同一套分工）
///
/// [PersonaCard]（core/persona_card.dart）是「这份人设被怎么理解」：每次由
/// 正文现算，不持久化。本层是人设**本身**：结构化字段 + 来源 + 名字。正文
/// 唯一来源是 [PersonaEntry.composedBody]——把称呼/关系/语气/边界/避谈/
/// 安全词六个编辑字段组装成 PersonaCard 认得的**键式正文**，promptText 预览
/// 与真实进提示词的东西因此永远是同一条路径（`PersonaCard.parse`）。
///
/// ## Character Card V2 兼容（用户校准项）
///
/// CCV2 卡的标准形状是 `{"spec":"chara_card_v2","spec_version":"2.0",
/// "data":{name, description, personality, scenario, first_mes, ...}}`；
/// 本层同时接受裸对象与 V1 别名（char_name/char_persona/example_dialogue）。
/// 映射见 [Ccv2Preview] 与 [PersonasController.importCcv2] 的注释——**导入
/// 必须先预览**（G8「确认后入库」的同一条纪律：机器解析的东西不直接落盘）。
///
/// ## 套用（本轮接线）
///
/// 人设创建后要能参与模型请求才有意义（外部审阅 ①：此前 PersonasPage 没有
/// 套用入口，人设卡与提示词链路是断的）。套用语义**复用 #13 收敛后的既有
/// 判定**：冲突/优先级判定唯一出处是 core 的 [StyleSource.resolve] /
/// [ExpertApply]（专家页同一套），本层不复制第二份 trim 判空。落点只有
/// 两个：ContactStore 的联系人人设、SettingsStore 的全局 style——写入口
/// 直接复用 experts_controller.dart 的 [StyleSinkPort] / [ContactPersonaSink]
/// 端口与适配器（只 import 消费，不改那个文件）。
///
/// **各库各持数据，套用不搬数据**：与 ExpertsController 的套用不同（那边会
/// 把条目落进「我的专家库」并记热度），人设套用只写两个 sink，不往专家库
/// 插条目、不记 usedCount——人设库与专家库是两份独立数据，谁也不并吞谁。
///
/// ## 持久化
///
/// shared_preferences 键 [PersonasController._storageKey] 整包 JSON。人设
/// 全是用户手写的非敏感字段，不走 secure storage（p0-plan F2 只针对 API
/// Key）；与 ContactStore 的 `contacts`、SettingsStore 的 `settings`、
/// ExpertsController 的 `experts` 键互不相干。
library;

import 'dart:convert';

import 'package:chartools_core/chartools_core.dart'
    show
        ConflictChoice,
        Contact,
        Expert,
        ExpertApply,
        ExpertSource,
        PersonaCard,
        StyleSource;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'experts_controller.dart'
    show ContactTarget, ContactPersonaSink, ExpertsController, StyleSinkPort;

/// 人设库里的一条。结构化字段直接存用户输入的**原值**（不做 PersonaCard
/// 那样的关键词展开），进提示词的正文由 [composedBody] 现场组装后交给
/// PersonaCard 解析——展开规则只活在 PersonaCard 一处，不在这里复刻。
class PersonaEntry {
  const PersonaEntry({
    required this.id,
    required this.name,
    this.description = '',
    this.address = '',
    this.relation = '',
    this.tone = '',
    this.boundaries = const [],
    this.avoid = const [],
    this.safeword = '',
    this.firstMes = '',
    this.extraBody = '',
    this.sourceRef = 'mine',
    this.updatedAt = 0,
  });

  final String id;

  /// 名字（列表展示 + 去重参考；不进提示词）。
  final String name;

  /// 简介一行，**只给人看，永不进提示词**（与 ContactProfile.notes 同一条
  /// 铁律，见 contact_store.dart:11-19 的注释——两层 notes 同名不同义）。
  /// 注意 CCV2 的 `description` 语义相反（角色描述、进提示词），导入时走
  /// [extraBody]，不落这里——见 importCcv2 的映射注释。
  final String description;

  // —— 以下六个编辑字段对应 PersonaCard 的键（页面的新建/编辑表单就这六项）——

  /// 称呼（PersonaCard 键「称呼」）。
  final String address;

  /// 关系（PersonaCard 键「关系」）。
  final String relation;

  /// 语气（PersonaCard 键「语气」）。
  final String tone;

  /// 硬边界（PersonaCard 键「硬边界」）：存用户写的**原词**（如「家人」），
  /// 组装进正文后由 PersonaCard._splitBoundaries 做关键词展开。
  final List<String> boundaries;

  /// 避谈（PersonaCard 键「避谈」）：约束我方措辞的词，与硬边界是两种东西
  /// （persona_card.dart:69-73 的区分），编辑器分两栏不让用户混。
  final List<String> avoid;

  /// 安全词（PersonaCard 键「安全词」）。
  final String safeword;

  /// 开场白（CCV2 `first_mes` 的落点）：组装正文时以「对方：」示例行的形式
  /// 进 PersonaCard 的 examples——它是角色说的话，恰好是示例对话的形状。
  final String firstMes;

  /// 补充正文：自由文本行，逐行进正文。CCV2 的 description / scenario /
  /// mes_example 与 persona 里认不出六个键的行都落这里——原样保留，
  /// PersonaCard.parse 认得其中带键的行（情境/主题/黄灯/语域……），
  /// 认不出的当散文进提示词，两边都不丢内容。
  final String extraBody;

  /// **来源追踪**（用户校准项）：`mine` = 手建；`copy:<原 id>` 前缀在
  /// [PersonasController.duplicate] 里不加（副本继承原件的出处）；
  /// `ccv2` / `ccv2:<spec_version>` = Character Card 导入。
  final String sourceRef;

  /// 最近修改的毫秒时间戳（列表排序 + 「刚改过」的依据）。
  final int updatedAt;

  /// 组装进提示词的正文：编辑字段的键式行 + 补充正文 + 开场白示例行。
  /// 键名与 core persona_card.dart:137-150 的别名表逐字对应，否则 parse
  /// 会静默退回自由文本——那种失败没有报错，只能靠测试挡（见
  /// personas_controller_test.dart 对 composedBody 的逐行断言）。
  String composedBody() {
    final lines = <String>[];
    if (address.trim().isNotEmpty) lines.add('称呼：${address.trim()}');
    if (relation.trim().isNotEmpty) lines.add('关系：${relation.trim()}');
    if (tone.trim().isNotEmpty) lines.add('语气：${tone.trim()}');
    if (boundaries.isNotEmpty) {
      lines.add('硬边界：'
          '${[
        for (final b in boundaries)
          if (b.trim().isNotEmpty) b.trim()
      ].join('、')}');
    }
    if (avoid.isNotEmpty) {
      lines.add('避谈：${[
        for (final a in avoid)
          if (a.trim().isNotEmpty) a.trim()
      ].join('、')}');
    }
    if (safeword.trim().isNotEmpty) lines.add('安全词：${safeword.trim()}');
    for (final l in extraBody.split('\n')) {
      if (l.trim().isNotEmpty) lines.add(l.trimRight());
    }
    final fm = firstMes
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (fm.isNotEmpty) {
      lines.add('示例：');
      // 多行开场白按行拆成多条「对方：」示例（PersonaCard 的示例按行认）。
      for (final l in fm) {
        lines.add('对方：${l.trim()}');
      }
    }
    return lines.join('\n');
  }

  /// 现算的结构化卡；与进提示词的路径完全同一条。
  PersonaCard card() => PersonaCard.parse(composedBody());

  /// 页面「提示词预览」用的文本：structured 卡是 `<persona_card>` 块，自由
  /// 补充原样返回——与起草提示词拿到的东西逐字一致。
  String promptPreview() => card().promptText();

  /// 列表卡片上的一行简介：有 [description] 用它，否则拿正文第一行并剥掉
  /// 短键名（「称呼：小明」→「小明」）——卡面上冒出「称呼：」是噪音
  /// （legacy ExpertCard.kt:58 的同一处理）。
  String blurb() {
    final d = description.trim();
    if (d.isNotEmpty) return d;
    for (final l in composedBody().split('\n')) {
      final t = l.trim();
      if (t.isEmpty) continue;
      final sep = t.indexOfFirst((c) => c == '：' || c == ':');
      if (sep >= 1 && sep <= 4) return t.substring(sep + 1).trim();
      return t;
    }
    return '';
  }

  /// 编辑表单预填用的边界/避谈原词（顿号连接），与 composedBody 对称。
  String get boundariesText => boundaries.join('、');
  String get avoidText => avoid.join('、');

  PersonaEntry copyWith({
    String? id,
    String? name,
    String? description,
    String? address,
    String? relation,
    String? tone,
    List<String>? boundaries,
    List<String>? avoid,
    String? safeword,
    String? firstMes,
    String? extraBody,
    String? sourceRef,
    int? updatedAt,
  }) =>
      PersonaEntry(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        address: address ?? this.address,
        relation: relation ?? this.relation,
        tone: tone ?? this.tone,
        boundaries: boundaries ?? this.boundaries,
        avoid: avoid ?? this.avoid,
        safeword: safeword ?? this.safeword,
        firstMes: firstMes ?? this.firstMes,
        extraBody: extraBody ?? this.extraBody,
        sourceRef: sourceRef ?? this.sourceRef,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'description': description,
        'address': address,
        'relation': relation,
        'tone': tone,
        'boundaries': List<String>.of(boundaries),
        'avoid': List<String>.of(avoid),
        'safeword': safeword,
        'firstMes': firstMes,
        'extraBody': extraBody,
        'sourceRef': sourceRef,
        'updatedAt': updatedAt,
      };

  /// 容错解析：缺字段落默认值、类型不对的项丢弃，绝不抛（坏存档不挡启动）。
  factory PersonaEntry.fromJson(Map<String, dynamic> j) => PersonaEntry(
        id: j['id'] is String ? j['id'] as String : '',
        name: j['name'] is String ? j['name'] as String : '',
        description:
            j['description'] is String ? j['description'] as String : '',
        address: j['address'] is String ? j['address'] as String : '',
        relation: j['relation'] is String ? j['relation'] as String : '',
        tone: j['tone'] is String ? j['tone'] as String : '',
        boundaries: _stringListOf(j['boundaries']),
        avoid: _stringListOf(j['avoid']),
        safeword: j['safeword'] is String ? j['safeword'] as String : '',
        firstMes: j['firstMes'] is String ? j['firstMes'] as String : '',
        extraBody: j['extraBody'] is String ? j['extraBody'] as String : '',
        sourceRef: j['sourceRef'] is String ? j['sourceRef'] as String : 'mine',
        updatedAt: j['updatedAt'] is int ? j['updatedAt'] as int : 0,
      );

  static List<String> _stringListOf(Object? raw) => [
        if (raw is List)
          for (final v in raw)
            if (v is String) v,
      ];

  @override
  bool operator ==(Object other) =>
      other is PersonaEntry && other.id == id && other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(id, updatedAt);
}

/// CCV2 导入的**预览**结果：只解析、不落库——用户在页面上看清每个字段会
/// 落到哪，点「确认导入」才由 [PersonasController.importCcv2] 建条目
/// （G8「确认后入库」的同一纪律：机器解析的东西不直接落盘）。
class Ccv2Preview {
  const Ccv2Preview({
    required this.ok,
    this.problem = '',
    this.name = '',
    this.description = '',
    this.persona = '',
    this.personality = '',
    this.scenario = '',
    this.mesExample = '',
    this.firstMes = '',
    this.specVersion = '',
  });

  final bool ok;

  /// 解析失败说明；空串 = 正常。
  final String problem;
  final String name;
  final String description;

  /// CCV2 标准字段里没有 `persona`（那是本仓库的扩展键）；V1 的
  /// char_persona 与手工改写的 persona 都认。
  final String persona;

  /// CCV2 的 personality：语气备胎——persona 里没认出语气时才补位
  /// （PersonasController.importCcv2 的映射表）。
  final String personality;

  /// CCV2 的 scenario：进补充正文并加「情境：」键前缀（PersonaCard 认）。
  final String scenario;

  /// CCV2 的 mes_example（V1 别名 example_dialogue）：逐行进补充正文，
  /// 行首 我：/对方： 前缀由 PersonaCard 认成示例。
  final String mesExample;
  final String firstMes;

  /// spec_version（展示用，也是 sourceRef 的一部分）。
  final String specVersion;

  /// 解析 Character Card JSON。任何异常收敛成 [problem]，绝不外抛。
  /// 接受三种形状：CCV2 包裹（spec + data）、裸对象（字段平铺）、V1 别名
  /// （char_name / char_persona / example_dialogue）。
  static Ccv2Preview parse(String json) {
    if (json.trim().isEmpty) {
      return const Ccv2Preview(ok: false, problem: '导入内容为空');
    }
    final Object? root;
    try {
      root = jsonDecode(json);
    } on FormatException catch (e) {
      return Ccv2Preview(ok: false, problem: '不是合法 JSON：${e.message}');
    }
    if (root is! Map<String, dynamic>) {
      return const Ccv2Preview(ok: false, problem: '根节点必须是对象');
    }
    // CCV2 包裹层：字段都在 data 里。没有 data 就当裸卡处理（V1/手工导出
    // 常见形状），两不误伤。
    final data = root['data'] is Map<String, dynamic>
        ? root['data'] as Map<String, dynamic>
        : root;
    String str(Object? v) => v is String ? v.trim() : '';
    final name = str(data['name']).isNotEmpty
        ? str(data['name'])
        : str(data['char_name']);
    return Ccv2Preview(
      ok: name.isNotEmpty,
      problem: name.isEmpty ? '不是有效的 Character Card（缺 name 字段）' : '',
      name: name,
      description: str(data['description']),
      persona: str(data['persona']).isNotEmpty
          ? str(data['persona'])
          : str(data['char_persona']),
      personality: str(data['personality']),
      scenario: str(data['scenario']),
      mesExample: str(data['mes_example']).isNotEmpty
          ? str(data['mes_example'])
          : str(data['example_dialogue']),
      firstMes: str(data['first_mes']).isNotEmpty
          ? str(data['first_mes'])
          : str(data['firstMes']),
      specVersion:
          str(root['spec_version']).isNotEmpty ? str(root['spec_version']) : '',
    );
  }
}

/// 人设库控制器：列表持久化 + 增改删复制 + CCV2 导入（预览 → 确认）+ 套用
/// （core ExpertApply 语义，见「套用」一节）。
///
/// 页面接线（main.dart `_openPersonas`）：`PersonasController(styleSink:
/// SettingsStyleSink(settings), contactSink: ContactStorePersonaSink(contacts))
/// ..load()`。两个 sink 可选（构造注入），缺位时套用动作如实报「未接线」，
/// 其余能力不受影响——与 ExpertsController 的接线口径一致。
class PersonasController {
  PersonasController({
    StyleSinkPort? styleSink,
    ContactPersonaSink? contactSink,
  })  : _styleSink = styleSink,
        _contactSink = contactSink {
    // core ExpertApply 的冲突/回滚判定都在 core；sink 缺位时 core 自己会报
    // 「没有通道」，这里构造照常（页面用 hasStyleSink/hasContactSink 提前拦）。
    _apply = ExpertApply(sink: _styleSink);
  }

  /// shared_preferences 里的存档键：名单整包一个 JSON。
  static const String _storageKey = 'personas';

  /// 全局风格写入口（experts_controller.dart 的端口复用，见套用一节）；
  /// null = 未接线（套用为全局风格如实报错）。
  final StyleSinkPort? _styleSink;

  /// 联系人人设写入口（同上）；null = 未接线（套用为联系人人设如实报错）。
  final ContactPersonaSink? _contactSink;

  /// 套用的唯一判定处（core）：needsChoice / 覆盖 / 并存 / 回滚全在那里，
  /// 本层只做接线检查与异步落盘 flush 的兜底（与 ExpertsController 同款）。
  late final ExpertApply _apply;

  /// 全部人设（updatedAt 降序即展示顺序；写回永远换新 List——ValueNotifier
  /// 按 identical 判定，与 ContactStore.contacts 同一纪律）。
  final ValueNotifier<List<PersonaEntry>> entries =
      ValueNotifier(const <PersonaEntry>[]);

  /// 应用启动时调用：读存档。坏存档（JSON 损坏、平台通道不可用）保持空
  /// 清单原样返回，与 ContactStore.load 同一口径。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.isEmpty) return;
      final Object? parsed;
      try {
        parsed = jsonDecode(raw);
      } on FormatException {
        return; // 整包 JSON 损坏：按没存过处理。
      }
      if (parsed is! Map<String, dynamic>) return;
      final list = parsed['personas'];
      if (list is! List) return;
      entries.value = <PersonaEntry>[
        for (final e in list)
          if (e is Map<String, dynamic>) PersonaEntry.fromJson(e),
      ];
    } catch (_) {
      // shared_preferences 不可用（平台通道缺失等）：保持内存空清单。
    }
  }

  // ------------------------------------------------------------------ 查询

  PersonaEntry? byId(String? id) {
    if (id == null) return null;
    for (final e in entries.value) {
      if (e.id == id) return e;
    }
    return null;
  }

  // -------------------------------------------------------- 套用（接线面）

  /// 全局风格写入口是否已接线（未接线时页面禁用套用为全局并如实提示）。
  bool get hasStyleSink => _styleSink != null;

  /// 联系人写入口是否已接线。
  bool get hasContactSink => _contactSink != null;

  /// 当前联系人目标快照（页面选套用目标、判断「已有专用人设」用）。
  List<ContactTarget> get contactTargets => _contactSink?.targets ?? const [];

  /// 「这位联系人是否写了专用人设」：**直接复用 ExpertsController.contactHasPersona**
  /// （它内部才是 core StyleSource.resolve 的收敛判定）。判定只活在 core 一处 +
  /// experts_controller 一个转发——本层不再写第二份 trim 判空，规则漂移不会分叉。
  static bool contactHasPersona(ContactTarget target) =>
      ExpertsController.contactHasPersona(target);

  // --------------------------------------------------------------- 增改删

  /// 上一次生成 id 的时间戳（微秒）。本机（Windows）实测系统时钟粒度是
  /// 毫秒级而非微秒级（dart 探针连读 50 万次只有十几个不同值）：create 与
  /// duplicate 同一刻内连发会拿到同一微秒值 → 同 id 撞车（duplicate 出的
  /// 「副本」与原件同 id，update 会互相顶掉）。与 [update] 里 updatedAt 的
  /// 「同一毫秒也要产出新实例」是同一类坑——id 这里用静态单调递增兜底：
  /// 同刻第二次生成取上次 +1，进程内严格递增永不重复；跨进程重启时钟必然
  /// 前进，不会撞旧存档的 id。
  static int _lastIdMicros = 0;

  /// 生成新人设 id：时间基（base36 微秒）+ 同刻单调递增兜底。
  static String _newId() {
    var micros = DateTime.now().microsecondsSinceEpoch;
    if (micros <= _lastIdMicros) micros = _lastIdMicros + 1;
    _lastIdMicros = micros;
    return 'p_${micros.toRadixString(36)}';
  }

  /// 新建人设并落盘。id 由本类生成，updatedAt 取当下，sourceRef 默认 `mine`。
  Future<PersonaEntry> create({
    required String name,
    String description = '',
    String address = '',
    String relation = '',
    String tone = '',
    List<String> boundaries = const [],
    List<String> avoid = const [],
    String safeword = '',
    String firstMes = '',
    String extraBody = '',
    String sourceRef = 'mine',
  }) async {
    final entry = PersonaEntry(
      id: _newId(),
      name: name.trim(),
      description: description,
      address: address,
      relation: relation,
      tone: tone,
      boundaries: List<String>.of(boundaries),
      avoid: List<String>.of(avoid),
      safeword: safeword,
      firstMes: firstMes,
      extraBody: extraBody,
      sourceRef: sourceRef,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    entries.value = [...entries.value, entry];
    await _persist();
    return entry;
  }

  /// 用编辑后的条目替换同 id 的旧条目并落盘；updatedAt 严格递增（同一毫秒
  /// 连续两次 update 也要产出不等的新实例，否则 ValueNotifier 会跳过赋值
  /// ——与 contact_store.dart:283 的同一处坑，不重蹈）。
  Future<void> update(PersonaEntry entry) async {
    final prev = byId(entry.id);
    if (prev == null) {
      throw StateError('PersonasController.update: id 不存在（${entry.id}），'
          '请改用 create');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = entry.copyWith(
        updatedAt: now > prev.updatedAt ? now : prev.updatedAt + 1);
    entries.value = <PersonaEntry>[
      for (final e in entries.value)
        if (e.id == entry.id) updated else e,
    ];
    await _persist();
  }

  /// 复制一条：新 id、名字加「（副本）」、updatedAt 取当下；**内容与来源
  /// 追踪字段原样继承**（副本的出处就是原件的出处，不另造一个来源）。
  /// id 不存在返回 null（幂等，页面提示用）。
  Future<PersonaEntry?> duplicate(String id) async {
    final src = byId(id);
    if (src == null) return null;
    final copy = src.copyWith(
      id: _newId(),
      name: '${src.name}（副本）',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    entries.value = [...entries.value, copy];
    await _persist();
    return copy;
  }

  /// 删除一条并落盘；id 不存在是空操作（幂等）。
  Future<void> remove(String id) async {
    final next = <PersonaEntry>[
      for (final e in entries.value)
        if (e.id != id) e,
    ];
    if (next.length == entries.value.length) return;
    entries.value = next;
    await _persist();
  }

  // ------------------------------------------------------- CCV2 导入（G8）

  /// 导入预览入口：只解析不落库，见 [Ccv2Preview]。
  Ccv2Preview previewCcv2(String json) => Ccv2Preview.parse(json);

  /// 用户确认后把预览落成一条人设。映射表（预览界面要按这条展示，让用户
  /// 看清每个 CCV2 字段落到哪）：
  ///
  /// - `name` → 名称（重名时自动加「（导入）」后缀，人设名在本库不强制唯一，
  ///   但重名会让列表分不清——加后缀比让用户事后改名省一步）；
  /// - `persona`（含 V1 别名 char_persona）→ 逐行认六个键（称呼/关系/语气/
  ///   硬边界/避谈/安全词，键别名是 PersonaCard 的子集），认不出的行**原样**
  ///   进补充正文——那里包括「情境/主题/黄灯/语域」这些 PersonaCard 认得的
  ///   键，组装后仍走 PersonaCard.parse，一个字都不丢；
  /// - `description` → 补充正文（**CCV2 的 description 是角色描述、进提示词**
  ///   的内容字段，与本库浏览层简介不同名不同义——照搬进简介会把角色内容
  ///   静默丢出提示词）；
  /// - `personality` → 语气（仅当 persona 里没认出语气）；
  /// - `scenario` → 补充正文，加「情境：」键前缀（PersonaCard 认这个键）；
  /// - `first_mes` → 开场白（示例行「对方：…」进 PersonaCard 的 examples）；
  /// - `mes_example`（V1 别名 example_dialogue）→ 补充正文（行首的
  ///   我：/对方：/{{user}}/{{char}} 前缀会被 PersonaCard 认成示例）。
  ///
  /// [preview] 未通过解析（ok=false）时抛 FormatException——调用方（页面）
  /// 只会在预览通过后启用导入按钮，这里是防误用的最后一把闸。
  Future<PersonaEntry> importCcv2(Ccv2Preview preview) async {
    if (!preview.ok) {
      throw FormatException(
          preview.problem.isEmpty ? '导入预览未通过' : preview.problem);
    }
    var address = '', relation = '', tone = '', safeword = '';
    final boundaries = <String>[];
    final avoid = <String>[];
    final extra = <String>[];

    for (final line in preview.persona.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final cut = _splitKeyLine(t);
      if (cut == null) {
        extra.add(t);
        continue;
      }
      final (field, value) = cut;
      switch (field) {
        case 'address':
          address = address.isEmpty ? value : address;
        case 'relation':
          relation = relation.isEmpty ? value : relation;
        case 'tone':
          tone = tone.isEmpty ? value : tone;
        case 'boundaries':
          boundaries.addAll(_splitList(value));
        case 'avoid':
          avoid.addAll(_splitList(value));
        case 'safeword':
          safeword = safeword.isEmpty ? value : safeword;
      }
    }
    if (tone.isEmpty && preview.personality.trim().isNotEmpty) {
      tone = preview.personality.trim();
    }
    if (preview.scenario.trim().isNotEmpty) {
      extra.add('情境：${preview.scenario.trim()}');
    }
    for (final l in preview.mesExample.split('\n')) {
      if (l.trim().isNotEmpty) extra.add(l.trim());
    }
    // CCV2 的 description 是进提示词的角色内容：排在 persona 补充之后，
    // 顺序稳定（同一次导入重跑结果一致）。
    for (final l in preview.description.split('\n')) {
      if (l.trim().isNotEmpty) extra.add(l.trim());
    }

    final name = _uniqueName(preview.name);
    return create(
      name: name,
      address: address,
      relation: relation,
      tone: tone,
      boundaries: boundaries,
      avoid: avoid,
      safeword: safeword,
      firstMes: preview.firstMes,
      extraBody: extra.join('\n'),
      sourceRef:
          preview.specVersion.isEmpty ? 'ccv2' : 'ccv2:${preview.specVersion}',
    );
  }

  /// 导入用的轻量键行拆分：`称呼：先生` / `address: sir`。键名归一化后查
  /// [_importKeyAliases]。与 PersonaCard._splitKeyValue 的差别只在**意图**：
  /// 这里只为导入预填，认不出的键整行进补充正文（PersonaCard 稍后仍会
  /// 完整解析一遍），所以不需要复刻它的全部容错。
  static const Map<String, String> _importKeyAliases = <String, String>{
    '称呼': 'address',
    '称谓': 'address',
    'address': 'address',
    'title': 'address',
    '关系': 'relation',
    '身份': 'relation',
    'relation': 'relation',
    'relationship': 'relation',
    'role': 'relation',
    '语气': 'tone',
    '口吻': 'tone',
    '语气风格': 'tone',
    'tone': 'tone',
    'style': 'tone',
    '边界': 'boundaries',
    '硬边界': 'boundaries',
    '底线': 'boundaries',
    '禁忌': 'boundaries',
    'limits': 'boundaries',
    'hardlimits': 'boundaries',
    'limit': 'boundaries',
    '避谈': 'avoid',
    '回避': 'avoid',
    'avoid': 'avoid',
    '安全词': 'safeword',
    'safeword': 'safeword',
  };

  static (String, String)? _splitKeyLine(String line) {
    final cn = line.indexOf('：');
    final en = line.indexOf(':');
    final at = cn < 0 ? en : (en < 0 ? cn : (cn < en ? cn : en));
    if (at <= 0 || at > 12) return null;
    final key = line.substring(0, at).trim();
    if (key.isEmpty) return null;
    final field = _importKeyAliases[_norm(key)];
    return field == null ? null : (field, line.substring(at + 1).trim());
  }

  static String _norm(String key) => key
      .trim()
      .toLowerCase()
      .replaceAll('-', '')
      .replaceAll('_', '')
      .replaceAll(' ', '');

  /// 边界/避谈的列表拆分：与 PersonaCard._splitBoundaries 用同一组分隔符；
  /// **不做关键词展开**——展开只发生在 PersonaCard.parse 里（组装后的正文
  /// 会过它），这里保留用户原词，编辑表单回填才不出现「提家人」这种衍生词。
  static List<String> _splitList(String value) => [
        for (final p in value.split(RegExp('[、,，;；/| \\n]+')))
          if (p.trim().isNotEmpty) p.trim(),
      ];

  /// 重名时加「（导入）」；连「（导入）」也重名就再加序号。
  String _uniqueName(String name) {
    final taken = {for (final e in entries.value) e.name};
    if (!taken.contains(name)) return name;
    var candidate = '$name（导入）';
    var i = 2;
    while (taken.contains(candidate)) {
      candidate = '$name（导入$i）';
      i++;
    }
    return candidate;
  }

  // ------------------------------------------------------------- 套用动作

  /// PersonaEntry → core Expert 的最小投影：套用真正写进目标的东西只有
  /// [PersonaEntry.composedBody]（与提示词预览同一条路径），tags/domain 等
  /// 浏览层字段一个字节都不进 persona/style（expert_apply.dart「只有
  /// promptText 进目标」的铁律）。core 不持久化这个投影，id/key 沿用人设 id
  /// 仅为本次判定的日志可读性；packId 置空 = 非包来源（与 ExpertShelfItem
  /// 对 `mine` 的口径一致）。
  Expert _expertOf(PersonaEntry entry) => Expert(
        id: entry.id,
        key: entry.id,
        name: entry.name,
        domain: '人设库',
        promptText: entry.composedBody(),
        source: const ExpertSource(packId: '', packVersion: ''),
      );

  Contact _coreContactOf(ContactTarget t) =>
      Contact(id: t.id, name: t.displayName, persona: t.persona);

  List<Contact> _coreContacts() => <Contact>[
        for (final t in contactTargets) _coreContactOf(t),
      ];

  /// 「套用为全局风格」。判定与落笔唯一出处是 core ExpertApply.applyToGlobal：
  /// 正文空拒绝、写失败回滚、shadowed 提示都在 core。本层保留两件事：接线
  /// 检查、异步落盘 flush 的成败兜底（core 的 sink 是同步接口，盘上成败由
  /// StyleSinkPort.flush 上交，失败在这里回滚内存并如实报错）——与
  /// ExpertsController.applyAsGlobalStyle 同款兜底，只是**不落库不记热度**
  /// （人设库与专家库各自持数据，套用不搬数据，见套用一节）。
  Future<PersonaApplyResult> applyAsGlobalStyle(PersonaEntry entry) async {
    final sink = _styleSink;
    if (sink == null) {
      return const PersonaApplyResult(
          ok: false, problem: '全局风格未接线（#13），暂时不能套用');
    }
    // 空正文套上去等于把人设清空（与 core 同一判定，提前拦是为了文案口径
    // 与 experts_page 一致：'「名字」没有正文，没套用'）。
    if (entry.composedBody().trim().isEmpty) {
      return PersonaApplyResult(ok: false, problem: '「${entry.name}」没有正文，没套用');
    }
    final previous = sink.style; // flush 失败要原样退回去
    final r = _apply.applyToGlobal(_expertOf(entry), contacts: _coreContacts());
    if (!r.ok) {
      return PersonaApplyResult(ok: false, problem: r.problem, note: r.note);
    }
    try {
      await sink.flush();
    } catch (e) {
      sink.style = previous;
      try {
        await sink.flush();
      } catch (_) {
        // 回滚也失败：problem 里照实说，不假装成功。
      }
      return PersonaApplyResult(
        ok: false,
        problem: '设置里那句人设没写成（$e），已经还原成原来那句',
      );
    }
    return PersonaApplyResult(ok: true, note: r.note);
  }

  /// 「套用为联系人人设」。冲突判定（专用人设压全局）唯一出处是 core
  /// StyleSource.resolve——ExpertApply.applyToContact 检测到冲突时返回
  /// needsChoice 且**两个目标都不动**，界面问完用户（覆盖/并存）带
  /// [ConflictChoice] 再调一次。并存路径 core 写全局 sink、盘上成败由 flush
  /// 兜底；覆盖路径 core 返回新 persona，联系人落盘走 ContactPersonaSink。
  /// 失败文案与 ExpertsController.applyToContact 同口径。
  Future<PersonaApplyResult> applyToContact(
    PersonaEntry entry,
    ContactTarget target, {
    ConflictChoice? choice,
  }) async {
    final contactSink = _contactSink;
    if (contactSink == null) {
      return const PersonaApplyResult(
          ok: false, problem: '联系人档案未接线（#13），暂时不能套用');
    }
    if (entry.composedBody().trim().isEmpty) {
      return PersonaApplyResult(ok: false, problem: '「${entry.name}」没有正文，没套用');
    }
    final styleBefore = _styleSink?.style ?? ''; // 并存要写全局，失败得还原
    final r = _apply.applyToContact(_expertOf(entry), _coreContactOf(target),
        choice: choice);
    // 冲突待裁决：core 保证两个目标都没写——界面弹「覆盖/并存」后再调。
    if (r.needsChoice) {
      return PersonaApplyResult(ok: false, needsChoice: true, note: r.note);
    }
    if (!r.ok) {
      return PersonaApplyResult(ok: false, problem: r.problem, note: r.note);
    }
    if (r.wroteGlobalStyle) {
      // 并存：人设正文已由 core 写进全局 sink，联系人专用人设没动。
      final sink = _styleSink;
      if (sink == null) {
        return PersonaApplyResult(
            ok: false, problem: '并存需要全局风格通道：控制器未接线 styleSink');
      }
      try {
        await sink.flush();
      } catch (e) {
        sink.style = styleBefore;
        try {
          await sink.flush();
        } catch (_) {
          // 回滚也失败：problem 里照实说。
        }
        return PersonaApplyResult(
          ok: false,
          problem: '全局风格没写成（$e），已经还原；'
              '「${target.displayName}」的专用人设没动',
        );
      }
      return PersonaApplyResult(ok: true, note: r.note);
    }
    // 覆盖/直写：把 core 给的 persona 落到联系人档案。写失败如实报 problem
    //（core 已保证内存写成功前不会返回 ok，这里只剩 app 层落盘一条路）。
    try {
      await contactSink.writePersona(target.id, r.appliedText);
    } catch (e) {
      return PersonaApplyResult(
        ok: false,
        problem: '「${target.displayName}」的专用人设没写成（$e），原句未改动',
      );
    }
    return PersonaApplyResult(ok: true, note: r.note);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(<String, dynamic>{
        'version': 1,
        'personas': <Map<String, dynamic>>[
          for (final e in entries.value) e.toJson(),
        ],
      }),
    );
  }

  void dispose() {
    entries.dispose();
  }
}

/// 一次人设套用的结果。[needsChoice] 为 true 时**什么都没写**——core
/// ExpertApply 检测到「专用人设压全局」的冲突，等界面问完用户（覆盖/并存）
/// 再带 [ConflictChoice] 调一次。与 ExpertApplyResult（experts_controller）
/// 的差别只在没有 profile 字段：人设套用不落专家库，没有「库里那条」可指。
class PersonaApplyResult {
  const PersonaApplyResult({
    required this.ok,
    this.needsChoice = false,
    this.problem = '',
    this.note = '',
    this.warning = '',
  });

  final bool ok;
  final bool needsChoice;

  /// 失败原因，给界面直接显示。
  final String problem;

  /// core 的冲突/优先级提示文案（needsChoice 与并存路径都有，界面照实念）。
  final String note;

  /// 降级说明，不影响套用（与 ExpertApplyResult 同形保留，当前路径不产）。
  final String warning;
}

/// String.indexOfFirst 的最小实现（dart:core 没有 take-while 式的 indexOf）。
extension _FirstWhereExt on String {
  int indexOfFirst(bool Function(String) test) {
    for (var i = 0; i < length; i++) {
      if (test(this[i])) return i;
    }
    return -1;
  }
}
