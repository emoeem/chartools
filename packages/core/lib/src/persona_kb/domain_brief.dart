import 'kb_models.dart';

/// 把一整个知识库预扫成**一段**领域卡，而不是每轮塞 5 段 BM25 命中的原始片段。
///
/// 为什么要有它（旧仓库 `_reports/kb-effect_report.md` 的实况 A/B）：同一个
/// 问卷、同一张人设卡，只换注入内容，让同一个模型盲评「像不像网调语境里
/// 会说的话」：
///
/// | 注入 | 提示词长度 | 盲评 |
/// | --- | --- | --- |
/// | 人设卡 + 5 段原始片段 | ~3,440 字 | 4.45 |
/// | 人设卡，无笔记 | ~255 字 | 4.12 |
/// | 笔记不变、去掉人设卡 | ~3,261 字 | 3.25 |
/// | 人设卡 + 一张领域卡 | ~910 字 | 4.60 |
///
/// 两个结论：**人设卡是最大的杠杆**（+1.20），原始片段的边际收益很小
/// （+0.33）而且把 3000 字塞进去会稀释人设；把整库先压成一张卡反而最高，
/// 长度只有 1/4。这也是「全书预扫 → 注入每批」在对话场景里的形态 ——
/// 锚点少、密度高、不随话题漂移。
///
/// 这个类只做**纯文字**的事，不发请求：[sample] 按来源均衡采样、[user] 拼
/// 提示词、[note] 把模型输出收成一条常驻笔记。请求走
/// `ReplyClient.domainBrief`（旧仓库 `core/kb/DomainBrief.kt` 的逐字移植，
/// 与离线脚本 `build_domain_brief.py` 是同一套采样与提示词 —— 那个脚本是
/// 离线实验路径，这里是生产路径。两边的抽样规则必须一起改）。
abstract final class DomainBrief {
  /// 默认的主题名；调用方通常用 PersonaCard 的主题，空则退回这个。
  static const String defaultTopic = '网调';

  /// 采样总量上限（字符）。再长只会让模型把同样的规则换个说法说两遍。
  static const int budgetChars = 24000;

  /// 每份来源文档分到的采样预算。
  static const int perDocChars = 1600;

  /// 每段只取开头这么多字 —— 够看出这段在讲什么，不必读完整段。
  static const int sampleChunk = 400;

  /// 领域卡的长度上限（汉字）。超了模型就开始复述情节。
  static const int maxHan = 900;

  /// 生成出来的笔记标题后缀；前面拼主题，所以一张卡只服务一个主题。
  static const String titleSuffix = '领域卡（自动预扫）';

  static String title(String topic) =>
      '${topic.trim().isEmpty ? defaultTopic : topic}$titleSuffix';

  static const String system =
      '你在给一个中文私密角色扮演助手写**领域设定卡**。用户和对方是成年人、自愿、'
      '已经约定好安全词和硬边界。这张卡会被逐字放进每次回复的提示词里，作用是让'
      '回复保持在这个语境的规矩、流程和说法里，而不是给出通用的安慰或说教。\n'
      '你只做归纳：素材里没有的东西不要编。用中文，不要 Markdown 标题符号，'
      '直接分小段写，每段以「词：」开头。';

  static String user(String topic, String sample) {
    final t = topic.trim().isEmpty ? defaultTopic : topic;
    return '下面是从一个「$t」知识库里按来源均衡采样出来的片段。请把它压缩成一张领域卡。\n'
        '\n'
        '要求（很严，超了就废）：\n'
        '1. 总长不超过 $maxHan 个汉字。\n'
        '2. 只写「让回复像这个语境里的话」所必需的东西，分这六段，每段一行到三行：\n'
        '   角色与关系：谁是什么身份，谁定规矩\n'
        '   称呼与语气：常用的称呼、说话的口吻和长度\n'
        '   典型流程：这类对话通常怎么推进（开场／布置／执行／汇报／收尾）\n'
        '   常用说法：这个领域里高频出现的词和句式（列 15-25 个词即可）\n'
        '   边界与安全：必须一直遵守的底线、安全词怎么用、事后怎么处理\n'
        '   不要做什么：最容易让回复「出戏」的几种写法\n'
        '3. 不要复述具体情节，不要写「根据素材」之类的元话，不要列表符号。\n'
        '4. 素材里反复出现但只是同一句话说很多遍的，合并成一句。\n'
        '\n'
        '素材：\n'
        '----------------\n'
        '$sample\n'
        '----------------';
  }

  /// 采样结果里一个来源文档的标题行，[sample] 用它分段。
  static String _header(String doc, int count) => '### 来源：$doc（共 $count 段）';

  /// 按来源均衡采样：先按来源文档分组，每份文档均匀取几段，总量封顶。
  ///
  /// 为什么不按长度取前 N 条：用户这套素材里最大的一本书（235,747 字 / 367 段）
  /// 占全库一半以上 —— 按长度排的话采样会被它一个人吃掉，领域卡就只剩那本书的
  /// 一家之言。按文档分组、每份先分到 [perDocChars] 的额度，主题才铺得开。
  ///
  /// 来源取 `tags[1]`（导入时写的是文件名），没有标签就退回标题。
  static String sample(
    List<Note> notes, {
    int budget = budgetChars,
    int perDoc = perDocChars,
  }) {
    final byDoc = <String, List<Note>>{};
    for (final n in notes) {
      if (!n.enabled) continue;
      final doc = (n.tags.length > 1 && n.tags[1].trim().isNotEmpty)
          ? n.tags[1]
          : (n.title.trim().isEmpty ? '（无标题）' : n.title);
      byDoc.putIfAbsent(doc, () => []).add(n);
    }
    if (byDoc.isEmpty) return '';

    final picked = <String>[];
    // 旧仓库 sortedByDescending 是稳定排序：段数相同时保持插入序。Dart 的
    // List.sort 不保证稳定，用下标作决胜键保持同一语义。
    final docs = byDoc.keys.toList();
    final order = List.generate(docs.length, (i) => i)
      ..sort((a, b) {
        final cmp = byDoc[docs[b]]!.length.compareTo(byDoc[docs[a]]!.length);
        return cmp != 0 ? cmp : a.compareTo(b);
      });
    for (final idx in order) {
      final doc = docs[idx];
      final items = byDoc[doc]!;
      final take = _max(1, perDoc ~/ sampleChunk);
      final step = _max(1, items.length ~/ take);
      picked.add(_header(doc, items.length));
      var i = 0;
      while (i < items.length) {
        if (picked.length * sampleChunk > budget) break;
        picked.add(_take(items[i].content, sampleChunk));
        i += step;
      }
      if (picked.length * sampleChunk > budget) break;
    }
    return picked.join('\n');
  }

  /// 把模型输出收成一条**常驻**笔记（`alwaysOn = true`），这样它每轮都在，
  /// 不靠 BM25 去猜这一轮该不该带上它。
  ///
  /// 返回 null 表示这段输出不能用（空，或者一个汉字都没有）。宁可什么都不存，
  /// 也不要存一段空壳进知识库 —— 它会静默地占掉每次分析的预算。
  ///
  /// 与旧仓库的签名差异：Kotlin 的 `id` 默认取 `KbStore.newId()`，而本包
  /// 不落盘、id 由存储层生成（见 kb_models.dart 的说明），所以这里必须由
  /// 调用方显式传入。
  static Note? note(String raw, String topic, {required String id, int? now}) {
    final body = normalize(raw);
    if (body == null) return null;
    return Note(
      id: id,
      title: title(topic),
      content: body,
      tags: ['领域卡', topic.trim().isEmpty ? defaultTopic : topic],
      alwaysOn: true,
      enabled: true,
      updatedAt: now ?? DateTime.now().millisecondsSinceEpoch,
      type: 'note',
    );
  }

  /// 清掉 Markdown 装饰、裁到 [maxHan] 个汉字；不可用时返回 null。
  static String? normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    // 模型偶尔会在外面套一段 ``` 或加粗，去掉不影响内容。
    if (s.startsWith('```')) s = s.substring(3);
    if (s.endsWith('```')) s = s.substring(0, s.length - 3);
    s = s.replaceAll('**', '').trim();
    s = [
      for (final line in s.split(RegExp(r'\r\n|\r|\n'))) line.trimRight(),
    ].join('\n').trim();
    final hans = hanCount(s);
    if (hans == 0) return null;
    if (hans <= maxHan) return s;
    // 超长就在最后一个句末处断，别把一句话劈成两半。
    var cut = -1;
    var seen = 0;
    for (var i = 0; i < s.length; i++) {
      if (_isHan(s.codeUnitAt(i))) seen++;
      if (seen >= maxHan) {
        cut = i;
        break;
      }
    }
    if (cut < 0) return s;
    final head = s.substring(0, cut + 1);
    final stop = head.lastIndexOf(RegExp(r'[。！？\n]'));
    return (stop > maxHan ~/ 2 ? head.substring(0, stop + 1) : head).trim();
  }

  static int hanCount(String s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      if (_isHan(s.codeUnitAt(i))) n++;
    }
    return n;
  }

  static bool _isHan(int ch) => ch >= 0x4e00 && ch <= 0x9fff;

  /// Kotlin `String.take(n)`：前 n 个字符，长度不足时全取。
  static String _take(String s, int n) => s.length <= n ? s : s.substring(0, n);

  static int _max(int a, int b) => a >= b ? a : b;
}
