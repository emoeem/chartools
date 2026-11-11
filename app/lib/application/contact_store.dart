import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 联系人档案（p0-plan #5「联系人档案简版」+ 外部审查报告第 4 节的设计约束
/// 「PersonaProfile：浏览信息 ≠ 提示词正文」）。
///
/// ## 两条硬约束（core 的 Contact 满足不了，才有了这一层）
///
/// 1. **浏览/正文分离（核心原则④）**：[ContactProfile.notes] 是给人看的
///    浏览信息（头像地址、标签、简介一类），**永不进提示词**——本类没有任何
///    把它写进提示词的通路，采集侧组装 ChatContext 时也刻意丢弃它（见
///    application/capture_session.dart 的 `_coreContactOf`）。进提示词的只有
///    [ContactProfile.relationship] / [ContactProfile.persona] /
///    [ContactProfile.avoidWords] 三个正文字段。
///    注意 core 的 `Contact.notes`（packages/core/lib/src/persona_kb/
///    kb_models.dart:76）语义相反——它经 `ChatContext.background()` 进提示词
///    （kb_models.dart:159）。两层的 notes 同名不同义，映射时绝不能照抄。
/// 2. **G8 确认后入库（核心原则③）**：模型猜测的事实（判断/起草结果里的
///    「她是研究生」「他们在合作」一类）**绝不自动写进** [ContactProfile]。
///    采集流水线（CaptureSession）只读本类，连引用都不持有；写路径只有
///    [ContactStore.create] / [ContactStore.update]（UI 的增改表单）与
///    [ContactStore.confirmStagedFact]（暂存区确认）。模型产出的候选走
///    [ContactStore.stageCandidateFact] 进暂存区，用户确认才落盘。
///
/// JSON 经 shared_preferences 的 `contacts` 键整包存取（与 SettingsStore 的
/// `settings` 键互不相干）。联系人名单全是用户手写的非敏感字段，不走
/// secure storage（p0-plan F2 只针对 API Key）。
class ContactProfile {
  const ContactProfile({
    required this.id,
    required this.displayName,
    this.aliases = const [],
    this.relationship = '',
    this.persona = '',
    this.avoidWords = const [],
    this.notes = '',
    this.updatedAt = 0,
  });

  /// 稳定 id：跨应用识别同一个人靠 [aliases]（core Contact 的既定语义），
  /// id 只做存档键与 activeContact 的指向，生成后不再变。
  final String id;

  /// 显示名：页面上的人名（core 侧映射成 `Contact.name`，进 background 的
  /// 「关于某某」行前提是 notes 非空——本层 notes 恒不外发，见上）。
  final String displayName;

  /// 跨应用别称：同一个人在 QQ / 飞书 / X 的会话标题（core Contact.aliases
  /// 的对应物）。当前版本只做展示与匹配原料，不进提示词。
  final List<String> aliases;

  /// 关系描述（进提示词正文）：联系人自己的关系，经 core 的
  /// effectiveRelationship 压过全局设置（kb_models.dart:177 的既定语义）。
  final String relationship;

  /// 人设正文（进提示词正文）：这个人的脾气、边界、称呼习惯。经 core 的
  /// StyleSource 压过全局 style（style_source.dart:29 的既定优先级），起草与
  /// 复查拿同一张卡。
  final String persona;

  /// 避免用词（进提示词正文）：对这个人不想用的词/说法——G7「反馈是结构化
  /// 的，不是往提示词里塞话」的落地：结构化清单，可查可改可删，采集侧按
  /// 一条固定标题的知识笔记承载进 ChatContext。
  final List<String> avoidWords;

  /// 浏览信息（头像/标签/简介一类）：**只给人看，永不进提示词**——本类的
  /// 硬约束，见类文档。
  final String notes;

  /// 最近一次修改的毫秒时间戳：列表按它排序展示，也用于「哪些字段改过」
  /// 的粗粒度提示。由 [ContactStore.update] 自动刷新。
  final int updatedAt;

  ContactProfile copyWith({
    String? id,
    String? displayName,
    List<String>? aliases,
    String? relationship,
    String? persona,
    List<String>? avoidWords,
    String? notes,
    int? updatedAt,
  }) =>
      ContactProfile(
        id: id ?? this.id,
        displayName: displayName ?? this.displayName,
        aliases: aliases ?? this.aliases,
        relationship: relationship ?? this.relationship,
        persona: persona ?? this.persona,
        avoidWords: avoidWords ?? this.avoidWords,
        notes: notes ?? this.notes,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 存档形状。键名固定，fromJson 与这里共用同一份形状；notes 字段照存——
  /// 它的「不进提示词」是消费侧的纪律（见类文档），不是不存。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'displayName': displayName,
        'aliases': List<String>.of(aliases),
        'relationship': relationship,
        'persona': persona,
        'avoidWords': List<String>.of(avoidWords),
        'notes': notes,
        'updatedAt': updatedAt,
      };

  /// 容错解析：缺字段落默认值，类型不对的项丢弃，绝不抛——坏存档不该挡住
  /// 启动（与 SettingsStore.load 同一口径）。
  factory ContactProfile.fromJson(Map<String, dynamic> j) => ContactProfile(
        id: j['id'] is String ? j['id'] as String : '',
        displayName:
            j['displayName'] is String ? j['displayName'] as String : '',
        aliases: _stringListOf(j['aliases']),
        relationship:
            j['relationship'] is String ? j['relationship'] as String : '',
        persona: j['persona'] is String ? j['persona'] as String : '',
        avoidWords: _stringListOf(j['avoidWords']),
        notes: j['notes'] is String ? j['notes'] as String : '',
        updatedAt: j['updatedAt'] is int ? j['updatedAt'] as int : 0,
      );

  static List<String> _stringListOf(Object? raw) => [
        if (raw is List) for (final v in raw) if (v is String) v,
      ];

  @override
  bool operator ==(Object other) =>
      other is ContactProfile && other.id == id && other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(id, updatedAt);
}

/// G8 暂存区里的一条候选事实：模型产出、等待用户确认的原文。
///
/// 暂存区**只在内存**（[ContactStore.stagedFacts]）：模型猜测的事实落盘之前
/// 必须过用户确认这一关（G8），所以确认前连磁盘都不碰——重启即清空是有意的。
class StagedCandidateFact {
  const StagedCandidateFact({
    required this.seq,
    required this.text,
    this.contactId,
    required this.stagedAt,
  });

  /// 暂存序号：进程内单调递增，作为这条候选的稳定句柄（确认/放弃都按它
  /// 匹配，[==] 也由它决定）。
  final int seq;

  /// 候选事实原文，原样暂存不加工。
  final String text;

  /// 暂存当时的激活联系人 id；null = 那一刻没有激活联系人。确认时默认落到
  /// 这个联系人，UI 也可以用 [ContactStore.confirmStagedFact] 的参数改投别人。
  final String? contactId;

  /// 暂存时刻的毫秒时间戳（展示「多久之前猜的」用）。
  final int stagedAt;

  @override
  bool operator ==(Object other) => other is StagedCandidateFact && other.seq == seq;

  @override
  int get hashCode => seq;
}

/// 联系人档案库：名单持久化 + 激活联系人切换 + G8 暂存区。
///
/// 与 [CaptureSession] 的契约：采集侧不持有本类（G8 隔离），UI 持有并在
/// 激活联系人变化（含档案被编辑/删除后的刷新）时把最新值喂给
/// `CaptureSession.applyContact`。见 capture_session.dart 顶部对该方法的说明。
class ContactStore {
  ContactStore();

  /// shared_preferences 里的存档键：名单整包一个 JSON。与 SettingsStore 的
  /// `settings` 键分开——两个库各自的形状各自演进，互不重写对方的键。
  static const String _storageKey = 'contacts';

  /// 全部联系人档案（存档顺序即展示顺序）。写回永远换新 List（ValueNotifier
  /// 按 identical 判定，原地改 List 不会通知）。
  final ValueNotifier<List<ContactProfile>> contacts =
      ValueNotifier(const <ContactProfile>[]);

  /// 当前激活联系人：null = 没有激活（采集流水线按「无联系人」跑）。
  ///
  /// **不持久化**（有意）：会话级状态的重启恢复归 C10 checkpoint 管——
  /// 「待确认恢复上次会话」提示上用户点了确认才由 UI 重新 setActive。这里
  /// 若静默存取激活选择，就等于绕过确认悄悄恢复了会话，违反 C10 的
  /// 「不静默恢复」。
  final ValueNotifier<ContactProfile?> activeContact =
      ValueNotifier<ContactProfile?>(null);

  /// G8 暂存区（内存态，重启即清空，见 [StagedCandidateFact] 的说明）：
  /// 模型猜的候选事实在这里等用户确认。只有 UI 写它（采集流水线够不着）。
  final ValueNotifier<List<StagedCandidateFact>> stagedFacts =
      ValueNotifier(const <StagedCandidateFact>[]);

  int _nextSeq = 1;

  /// 应用启动时调用：读存档灌入 [contacts]。坏存档（JSON 损坏、平台通道
  /// 不可用）保持空清单原样返回，与 SettingsStore.load 同一口径。
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
      final list = parsed['contacts'];
      if (list is! List) return;
      contacts.value = <ContactProfile>[
        for (final e in list)
          if (e is Map<String, dynamic>) ContactProfile.fromJson(e),
      ];
    } catch (_) {
      // shared_preferences 不可用（平台通道缺失等）：保持内存空清单。
    }
  }

  // ------------------------------------------------------------------ 查询

  /// 按 id 查档案；查不到（含 id 为 null）返回 null。
  ContactProfile? byId(String? id) {
    if (id == null) return null;
    for (final c in contacts.value) {
      if (c.id == id) return c;
    }
    return null;
  }

  // ------------------------------------------------------------------ 增改删

  /// 新建档案并落盘。id 由本类生成（时间戳派生），updatedAt 取当下。
  /// 返回建好的档案，UI 拿它继续编辑或直接 setActive。
  Future<ContactProfile> create({
    required String displayName,
    List<String> aliases = const [],
    String relationship = '',
    String persona = '',
    List<String> avoidWords = const [],
    String notes = '',
  }) async {
    final profile = ContactProfile(
      id: 'c_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      displayName: displayName,
      aliases: List<String>.of(aliases),
      relationship: relationship,
      persona: persona,
      avoidWords: List<String>.of(avoidWords),
      notes: notes,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    contacts.value = [...contacts.value, profile];
    await _persist();
    return profile;
  }

  /// 用编辑后的档案替换同 id 的旧档案并落盘；updatedAt 自动刷到当下。
  /// 被替换的正是激活联系人时，[activeContact] 同步换成新实例（监听方拿到
  /// 的永远是最新的字段值，不需要自己重新 byId）。
  Future<void> update(ContactProfile profile) async {
    // 存在性判断不能用替换推导的长度比较：逐元素映射不改变列表长度，判不
    // 出替换是否命中。直接查名单。
    final prev = byId(profile.id);
    if (prev == null) {
      // id 不在名单里：update 不是 upsert，静默忽略会把编辑结果弄丢——抛出
      // 让调用方（编辑页）显式决定新建还是提示。
      throw StateError('ContactStore.update: id 不存在（${profile.id}），'
          '请改用 create');
    }
    // updatedAt 按「同一联系人上一次修改」严格递增：同一毫秒内连续两次
    // update 会产出 updatedAt 相同的新旧实例，而 ContactProfile.== 按
    // (id, updatedAt) 判等、ValueNotifier 的 value setter 对相等的值跳过
    // 赋值——activeContact 就会停在旧实例上，监听方拿不到最新字段值，
    // 违反本方法「同步换成新实例」的契约。递增时间戳让每次 update 的产出
    // 都与旧值不等，赋值必然生效。
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = profile.copyWith(
        updatedAt: now > prev.updatedAt ? now : prev.updatedAt + 1);
    final next = <ContactProfile>[
      for (final c in contacts.value)
        if (c.id == profile.id) updated else c,
    ];
    contacts.value = next;
    if (activeContact.value?.id == profile.id) {
      activeContact.value = updated;
    }
    await _persist();
  }

  /// 删除档案并落盘；删的正是激活联系人时一并清空 [activeContact]（下一个
  /// 轮次按「无联系人」跑）。id 不存在是空操作（幂等）。
  Future<void> remove(String id) async {
    final next = <ContactProfile>[
      for (final c in contacts.value)
        if (c.id != id) c,
    ];
    if (next.length == contacts.value.length) return;
    contacts.value = next;
    if (activeContact.value?.id == id) activeContact.value = null;
    await _persist();
  }

  /// 切换激活联系人；id 不在名单里（或传 null）= 取消激活。只改内存不落盘，
  /// 理由见 [activeContact] 的文档（C10 不静默恢复）。
  void setActive(String? id) {
    activeContact.value = byId(id);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(<String, dynamic>{
        'version': 1,
        'contacts': <Map<String, dynamic>>[
          for (final c in contacts.value) c.toJson(),
        ],
      }),
    );
  }

  // ------------------------------------------------------- G8 确认后入库

  /// G8 暂存区入口：把一条模型猜测的候选事实放进暂存区，等用户确认。
  ///
  /// 调用方只有 UI（采集流水线不持有本类，结构性隔离 G8）：判断/起草结果里
  /// 用户点「记住这条」时调它。此时**什么都没落盘**——候选只进内存
  /// [stagedFacts]，用户在确认卡上点了「确认」才由 [confirmStagedFact] 写进
  /// 档案正文；点了「放弃」走 [discardStagedFact]，就此消失。
  void stageCandidateFact(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    stagedFacts.value = [
      ...stagedFacts.value,
      StagedCandidateFact(
        seq: _nextSeq++,
        text: trimmed,
        contactId: activeContact.value?.id,
        stagedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ];
  }

  /// 确认事实追加进 persona 的行数上限（fix(#9 K-5)）：persona 是提示词
  /// 正文，无界增长会推高 token 成本并稀释其它字段——最多保留最近 30 行，
  /// 超限从最旧（最前）一行开始淘汰。
  static const int _personaLineLimit = 30;

  /// 用户确认了一条候选：追加进目标联系人的人设正文（[ContactProfile.persona]
  /// ——进提示词的正文；此时它已经是用户确认过的事实，G8 的关卡已过）并落盘，
  /// 然后把它移出暂存区。
  ///
  /// 目标联系人按 targetContactId → 候选自带的 contactId → 当前激活联系人的
  /// 顺序解析；三者都落空时返回 null、候选**留在暂存区**（UI 提示先选一个
  /// 联系人再确认）。落盘失败原样抛出、候选保留，用户可重试。返回确认后
  /// 的最新档案（已同步进 [contacts] 与 [activeContact]）。
  ///
  /// fix(#9 K-5) 追加的两条约束（按行处理——persona 没有行级来源标记，手写
  /// 的多行正文与确认事实共享同一份行预算）：
  /// - **去重**：候选文本与 persona 现有某一行相同（两边都按 trim 后比较）
  ///   时不重复追加。此时没有任何变化值得写：不改 persona、不落盘、不刷新
  ///   updatedAt，候选照常移出暂存区、返回现档案。
  /// - **上限**：追加后超过 [_personaLineLimit] 行时淘汰最旧行。
  Future<ContactProfile?> confirmStagedFact(
    StagedCandidateFact fact, {
    String? targetContactId,
  }) async {
    final target = byId(targetContactId) ?? byId(fact.contactId) ?? activeContact.value;
    if (target == null) return null;
    // fix(#9 K-5) 空正文算 0 行：''.split('\n') 会得到一个空串行，照搬会让
    // 首次追加产出前导空行。
    final existingLines =
        target.persona.isEmpty ? const <String>[] : target.persona.split('\n');
    final text = fact.text.trim();
    // fix(#9 K-5) 去重：同文本（trim 后逐行比较）已在正文里、或候选 trim 后
    // 为空（没有可入库的内容），都不追加。
    final duplicate =
        text.isEmpty || existingLines.any((line) => line.trim() == text);
    if (!duplicate) {
      var nextLines = <String>[...existingLines, text];
      // fix(#9 K-5) 上限：超限淘汰最旧（最前）的行，保住最近 30 行。
      if (nextLines.length > _personaLineLimit) {
        nextLines = nextLines.sublist(nextLines.length - _personaLineLimit);
      }
      await update(target.copyWith(persona: nextLines.join('\n')));
    }
    stagedFacts.value = [
      for (final f in stagedFacts.value)
        if (f != fact) f,
    ];
    // 非 null 返回值即「确认成功」的契约（capture_page._confirm 据此提示）：
    // 去重路径没有产生新实例，返回名单里现存的这份即可。
    return byId(target.id);
  }

  /// 用户放弃一条候选：只移出暂存区，任何档案都不动。
  void discardStagedFact(StagedCandidateFact fact) {
    stagedFacts.value = [
      for (final f in stagedFacts.value)
        if (f != fact) f,
    ];
  }

  /// 清空暂存区（UI 的「全部放弃」入口）。
  void clearStagedFacts() {
    stagedFacts.value = const <StagedCandidateFact>[];
  }

  void dispose() {
    contacts.dispose();
    activeContact.dispose();
    stagedFacts.dispose();
  }
}
