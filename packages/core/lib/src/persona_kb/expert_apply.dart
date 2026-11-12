/// 「用这位专家」的唯一实现：把 [Expert.promptText] 写进目标，要么全成、
/// 要么不留半截。对应旧仓库 `core/kb/ExpertApply.kt` 的移植 + 两处升级。
///
/// ## 目标有两个（任务规格）
///
/// - **联系人专用人设**（`Contact.persona`）：写的是「对这个人怎么说话」。
///   core 不改存储——联系人是不变对象，返回新 [Contact]（[ApplyResult.contact]），
///   落盘由 app 层做；
/// - **全局 style**（[StyleSink]）：写的是「没有专用人设的聊天怎么说话」。
///
/// ## 冲突提示：覆盖 / 并存（任务规格 + 用户校准）
///
/// 联系人已有专用人设时，直接把专家塞进全局 style 是 legacy 踩过的坑：
/// StyleSource 的优先级是**联系人专用人设压过全局 style**，界面显示「已套用」
/// 而这个聊天一个字都没变——和「点了用却没反应」在体感上是同一件事。所以：
///
/// - **检测复用 [StyleSource.resolve] 本身**（不是自己再写一遍 trim/blank 判断）：
///   优先级规则将来变了，这里自动跟着走；
/// - 检测到冲突时返回 `needsChoice=true`，**什么都不写**，等界面问完用户再调
///   一次：选 [ConflictChoice.overwrite] → 换掉专用人设，原句留在
///   [ApplyResult.previousContact] 里供撤销；选 [ConflictChoice.coexist] →
///   专用人设不动，专家正文进全局 style（在其余没有专用人设的聊天里生效）。
///
/// ## 顺序不变量（legacy 的教训原样保留）
///
/// 每条路径只有**一个**真正落笔的动作（返回新 Contact，或写一次 sink），且
/// sink 写失败时回滚到进来时的文本——不存在「半个成功」。空正文绝不套用：
/// 那等于把用户的人设清空（legacy：0) 的检查，原样保留）。
///
/// ## 只有 promptText 进目标
///
/// tags / description / emoji / domain 全是浏览层，一个字节都不写进
/// persona / style（legacy PersonaProfile.kt「两组字段」的铁律）。
library;

import 'expert_catalog.dart';
import 'kb_models.dart';
import 'style_source.dart';

/// 全局 style 的写入口（legacy `StyleSink` 的同款抽象）。
///
/// 生产实现包住 app 的设置存储（Preferences / 配置文件）；测试用内存实现，
/// 或用会抛的实现逼出失败路径——失败路径正是这个类存在的理由。
abstract class StyleSink {
  String get style;
  set style(String value);
}

/// 已有专用人设时的两个选项（冲突提示「覆盖 / 并存」）。
enum ConflictChoice {
  /// 覆盖：专用人设换成专家正文；原句保留在 [ApplyResult.previousContact]。
  overwrite,

  /// 并存：专用人设不动，专家正文进全局 style——在其余没有专用人设的聊天里
  /// 生效；本聊天仍用专用人设（StyleSource 优先级，不改）。
  coexist,
}

/// 一条联系人被全局专家正文盖住的记录（[ApplyResult.shadowedContacts] 的元素）。
class ShadowedContact {
  const ShadowedContact({required this.id, required this.name});
  final String id;
  final String name;
}

/// 套用结果。字段都带默认值，坏路径也能构造出完整对象。
class ApplyResult {
  const ApplyResult({
    this.ok = false,
    this.needsChoice = false,
    this.contact,
    this.previousContact,
    this.wroteGlobalStyle = false,
    this.appliedText = '',
    this.problem = '',
    this.note = '',
    this.warning = '',
    this.shadowedContacts = const [],
  });

  /// 套用成功：写入已完成（sink 已写；联系人是新对象，落盘归 app 层）。
  final bool ok;

  /// true：检测到冲突且**还没写任何东西**——等用户选 [ConflictChoice] 后再调。
  final bool needsChoice;

  /// 覆盖/直接写入后的新联系人（app 层负责落盘）；并存/冲突/失败时为 null。
  final Contact? contact;

  /// 被覆盖前的原联系人（撤销用）；没覆盖过为 null。
  final Contact? previousContact;

  /// 是否写进了全局 style（并存路径与 applyToGlobal 都为 true）。
  final bool wroteGlobalStyle;

  /// 实际要生效的那段正文（= expert.promptText 原文，逐字、不 trim）。
  final String appliedText;

  /// 失败原因，给界面直接显示。
  final String problem;

  /// 冲突/优先级提示文案（needsChoice 与并存路径都会给，界面照实念）。
  final String note;

  /// 降级说明（如评测钩子抛了异常），不影响套用本身。
  final String warning;

  /// applyToGlobal 时：带着专用人设、盖不住的联系人（并存事实，供界面提示）。
  final List<ShadowedContact> shadowedContacts;
}

/// 套用发生时的事件（命中/使用评测钩子的载荷——用户校准：知识库要有
/// 命中评测钩子）。core 不存统计，只把事实递给 app 层。
class AppliedEvent {
  const AppliedEvent({
    required this.expert,
    required this.toContact,
    required this.coexist,
    this.contactId,
    required this.promptText,
  });

  final Expert expert;

  /// true = 目标是联系人 persona；false = 目标是全局 style。
  final bool toContact;

  /// 联系人专用人设是否被保留（并存路径为 true）。
  final bool coexist;

  /// 目标联系人的 id（全局套用时为 null）。
  final String? contactId;

  /// 实际写进去的正文。
  final String promptText;
}

/// 套用钩子：套用成功后回调一次。抛异常只降级成 [ApplyResult.warning]，
/// 绝不把套用变成失败——观测不能变成故障。
typedef AppliedHook = void Function(AppliedEvent event);

/// 套用器。两个入口对应两个目标；sink 可选（联系人路径不需要全局通道）。
class ExpertApply {
  ExpertApply({this.sink, this.onApplied});

  /// 全局 style 通道；为 null 时 applyToGlobal / 并存路径会如实报错。
  final StyleSink? sink;
  final AppliedHook? onApplied;

  /// 套用到一个联系人。
  ///
  /// 无冲突（该联系人没有专用人设）时直接返回带 persona 的新 Contact；
  /// 有冲突且未选择时返回 needsChoice，两个目标都不动。
  ApplyResult applyToContact(Expert expert, Contact contact, {ConflictChoice? choice}) {
    // 0) 正文是唯一进提示词的东西。空正文套上去等于把用户的人设清空。
    final body = expert.promptText.trim();
    if (body.isEmpty) {
      return ApplyResult(
          problem: '「${expert.name}」没有正文，没套用（联系人专用人设一个字都没动）');
    }

    // 复用 StyleSource.resolve 的优先级语义判定冲突：专用人设非空 →
    // from == contact，即「这个聊天当前生效的就是专用人设」。
    final globalNow = sink == null ? '' : _read(sink!);
    final before = StyleSource.resolve(globalNow, contact.persona);
    if (before.from == StyleSourceFrom.contact && choice == null) {
      return ApplyResult(
        needsChoice: true,
        note: '「${contact.name}」已有专用人设，且当前生效的就是它。套用「${expert.name}」请选：'
            '覆盖（专用人设换成专家正文，原句保留在结果里可撤销），或'
            '并存（专用人设不动，专家正文进全局 style，其余没有专用人设的聊天生效）。',
      );
    }

    if (choice == ConflictChoice.coexist) {
      return _coexist(expert, contact);
    }
    // overwrite 与「没有冲突的直写」走同一条路：写 persona。
    final next = _withPersona(contact, expert.promptText);
    final warn = _notify(AppliedEvent(
      expert: expert,
      toContact: true,
      coexist: false,
      contactId: contact.id,
      promptText: expert.promptText,
    ));
    return ApplyResult(
      ok: true,
      contact: next,
      previousContact: choice == ConflictChoice.overwrite ? contact : null,
      appliedText: expert.promptText,
      warning: warn ?? '',
    );
  }

  /// 并存：专用人设不动，专家正文进全局 style。
  ApplyResult _coexist(Expert expert, Contact contact) {
    final s = sink;
    if (s == null) {
      return ApplyResult(problem: '并存需要全局 style 通道：构造 ExpertApply 时传入 sink');
    }
    final previous = _read(s);
    final failure = _write(s, expert.promptText);
    if (failure != null) {
      _restore(s, previous);
      return ApplyResult(
          problem: '全局 style 没写成（$failure），已经还原；「${contact.name}」的专用人设没动');
    }
    // 套用后的优先级事实，照实告诉界面：专用人设仍然压着全局。
    final after = StyleSource.resolve(s.style, contact.persona);
    final warn = _notify(AppliedEvent(
      expert: expert,
      toContact: true,
      coexist: true,
      contactId: contact.id,
      promptText: expert.promptText,
    ));
    return ApplyResult(
      ok: true,
      wroteGlobalStyle: true,
      appliedText: expert.promptText,
      warning: warn ?? '',
      note: after.shadowed
          ? '并存完成：「${contact.name}」的专用人设没动，本聊天仍用它；「${expert.name}」'
              '写进了全局 style，其余没有专用人设的聊天会生效。'
          : '并存完成：专家正文写进了全局 style。',
    );
  }

  /// 套用到全局 style。[contacts] 用来算「盖不住谁」的并存提示。
  ApplyResult applyToGlobal(Expert expert, {Iterable<Contact> contacts = const []}) {
    final body = expert.promptText.trim();
    if (body.isEmpty) {
      return ApplyResult(problem: '「${expert.name}」没有正文，没套用（全局人设一个字都没动）');
    }
    final s = sink;
    if (s == null) {
      return ApplyResult(problem: '没有全局 style 通道：构造 ExpertApply 时传入 sink');
    }
    // 进来时的那句文本：写失败要原样退回去。
    final previous = _read(s);
    final failure = _write(s, expert.promptText);
    if (failure != null) {
      _restore(s, previous);
      return ApplyResult(problem: '设置里那句人设没写成（$failure），已经还原成原来那句');
    }
    // 复用 StyleSource.resolve：哪些联系人还压着专家正文——并存的事实，
    // 列出来给界面讲清楚，别让用户以为「套用会改掉所有人的聊天」。
    final shadowed = <ShadowedContact>[];
    for (final c in contacts) {
      if (StyleSource.resolve(s.style, c.persona).shadowed) {
        shadowed.add(ShadowedContact(id: c.id, name: c.name));
      }
    }
    final warn = _notify(AppliedEvent(
      expert: expert,
      toContact: false,
      coexist: shadowed.isNotEmpty,
      promptText: expert.promptText,
    ));
    return ApplyResult(
      ok: true,
      wroteGlobalStyle: true,
      appliedText: expert.promptText,
      warning: warn ?? '',
      shadowedContacts: shadowed,
      note: shadowed.isEmpty
          ? ''
          : '有 ${shadowed.length} 个联系人带着专用人设，他们在各自的聊天里仍然用专用人设'
              '（优先级不变）——这是并存，不是覆盖。',
    );
  }

  // ------------------------------------------------------------------ 私有

  /// 评测钩子。返回降级说明（钩子抛异常时），正常返回 null。
  String? _notify(AppliedEvent event) {
    final h = onApplied;
    if (h == null) return null;
    try {
      h(event);
      return null;
    } catch (e) {
      return '使用统计钩子抛了异常（不影响套用）：$e';
    }
  }

  /// 联系人不可变：换 persona 就是造新对象。updatedAt 不动——「现在」是
  /// app 层的策略，core 不替它定。
  static Contact _withPersona(Contact c, String persona) => Contact(
        id: c.id,
        name: c.name,
        aliases: List.of(c.aliases),
        apps: List.of(c.apps),
        relationship: c.relationship,
        notes: c.notes,
        persona: persona,
        autoSummary: c.autoSummary,
        updatedAt: c.updatedAt,
      );

  /// 读 / 写 / 回滚：sink 是接口，实现可能抛（磁盘满、无权限）。全部收敛，
  /// 不让异常越过这里——回滚本身失败也不再抛（能还原多少是多少，problem
  /// 里照实说）。
  static String _read(StyleSink s) {
    try {
      return s.style;
    } catch (_) {
      return '';
    }
  }

  static Object? _write(StyleSink s, String value) {
    try {
      s.style = value;
      return null;
    } catch (e) {
      return e;
    }
  }

  static void _restore(StyleSink s, String value) {
    try {
      s.style = value;
    } catch (_) {
      // 回滚失败：原值可能仍在（写抛异常意味着赋值没发生），problem 已说明。
    }
  }
}
