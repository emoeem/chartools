/// Local knowledge base data model (v1.3, D stage) —— 与旧仓库 `core/kb/KbModels.kt`
/// 一一对应。旧仓库里这些数据只存 app 私有目录的 JSON；本包不落盘，
/// 存储由 app 层（或测试里的内存实现）注入。
library;

import '../models/models.dart';
import 'ledger.dart';

/// [Note.type] marking a few-shot sample of the user's own writing voice
/// rather than a fact. The reply prompt quotes such a note as
/// `<user_style_examples>`; it is deliberately kept OUT of
/// [ChatContext.background], because the judge reads the background to
/// understand the situation and a style sample is not something anyone
/// actually said.
const String noteTypeStyleSample = 'style_sample';

/// One free-text knowledge note the user maintains by hand.
class Note {
  const Note({
    required this.id,
    required this.title,
    required this.content,
    this.tags = const [],
    this.alwaysOn = false,
    this.enabled = true,
    this.updatedAt = 0,
    this.type = 'note',
  });

  final String id;
  final String title;
  final String content;
  final List<String> tags;

  /// Always injected regardless of what the conversation is about.
  final bool alwaysOn;
  final bool enabled;
  final int updatedAt;
  final String type;

  Note copyWith({List<String>? tags}) => Note(
        id: id,
        title: title,
        content: content,
        tags: tags ?? this.tags,
        alwaysOn: alwaysOn,
        enabled: enabled,
        updatedAt: updatedAt,
        type: type,
      );
}

/// One person (or group) the user chats with. [aliases] is what makes a contact
/// cross-app: the same person shows up as different conversation titles in
/// QQ / Feishu / X, and each of those titles can be listed here.
class Contact {
  const Contact({
    required this.id,
    required this.name,
    this.aliases = const [],
    this.apps = const [],
    this.relationship = '',
    this.notes = '',
    this.persona = '',
    this.autoSummary = '',
    this.updatedAt = 0,
  });

  final String id;
  final String name;
  final List<String> aliases;

  /// Package names this contact has been seen in, e.g. com.tencent.mobileqq.
  final List<String> apps;
  final String relationship;
  final String notes;
  final String persona;

  /// Reserved for the (deferred) auto-summary; never written in v1.3.
  final String autoSummary;
  final int updatedAt;
}

/// One remembered chat line. side is "me" / "other", matching [Msg].
class LogEntry {
  const LogEntry({
    required this.side,
    required this.text,
    this.ts = 0,
    this.app = '',
  });

  final String side;
  final String text;
  final int ts;
  final String app;

  Msg toMsg() => Msg(side: side, text: text, at: ts);
}

/// A skill body that matched this round. (旧仓库 `core/skill/SkillMatcher` 的
/// SkillHit 的领域面——匹配器本身属于采集/技能层，这里只承接结果。)
class SkillHit {
  const SkillHit({required this.name, this.body = '', this.extra = ''});
  final String name;
  final String body;
  final String extra;
}

/// What one analysis gets to see beyond the on-screen messages: who the other
/// party is, older history for them, and the knowledge notes that matched.
class ChatContext {
  const ChatContext({
    this.contact,
    this.history = const [],
    this.notes = const [],
    this.skills = const [],
    this.catalogue = '',
    this.ledger,
  });

  final Contact? contact;
  final List<LogEntry> history;
  final List<Note> notes;

  /// Skills pulled in for THIS round (normally zero or one), already scored.
  /// The always-on L1 catalogue travels separately, in the reply prompt, since
  /// every enabled skill contributes to it.
  final List<SkillHit> skills;

  /// The L1 catalogue (`<available_skills>…`) of every enabled skill, or "".
  /// Always-on for the reply prompt, never part of [background] — Jev judges
  /// the conversation, it has no business reading instructions for the writer.
  final String catalogue;

  /// S1 会话台账：整段对话预扫出来的结构化卡片，见 [Ledger]。
  /// 只进**回复**提示词，不进 Jev 的 state。
  final Ledger? ledger;

  /// True when there is nothing extra to inject (then no field is sent at all).
  bool isEmpty() =>
      history.isEmpty &&
      notes.isEmpty &&
      (contact == null ||
          (contact!.relationship.trim().isEmpty &&
              contact!.notes.trim().isEmpty &&
              contact!.autoSummary.trim().isEmpty));

  /// The `background` string injected into Jev's state and the reply prompt:
  /// relationship + contact notes + auto-summary + each matched note as
  /// "title: content". Blank when there is nothing to say — callers must then
  /// omit the field entirely rather than send an empty one.
  String background(String defaultRelationship) {
    final sb = StringBuffer();
    final c = contact;
    if (c != null) {
      final rel = c.relationship.trim();
      if (rel.isNotEmpty) sb.write('关系：$rel\n');
      if (c.notes.trim().isNotEmpty) sb.write('关于${c.name}：${c.notes.trim()}\n');
      if (c.autoSummary.trim().isNotEmpty) {
        sb.write('过往摘要：${c.autoSummary.trim()}\n');
      }
    }
    for (final n in notes) {
      if (n.type == noteTypeStyleSample) continue;
      sb.write('${n.title.trim()}: ${n.content.trim()}\n');
    }
    return sb.toString().trim();
  }
}

/// 这一轮真正生效的关系：联系人自己写的关系优先，没写才用全局设置。
///
/// 为什么必须是它：起草、判断、复查三条路都要拿「对方和我是什么关系」，
/// 各自直读全局设置的话，一个存了联系人的会话里会出现两行打架的「关系：」
/// ——模型两头都想贴，写出来的就是那种既不像客户服务又不像朋友聊天的怪腔。
String effectiveRelationship(ChatContext? ctx, String fallback) {
  final contactRel = ctx?.contact?.relationship.trim() ?? '';
  return contactRel.isEmpty ? fallback : contactRel;
}
