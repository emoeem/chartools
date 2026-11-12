/// 文档导入：解析块流 → 笔记候选（K-7）。
///
/// 与 legacy 的分工：旧仓库 DocImport.kt 只产无标题等长 chunk（`名字 (i/n)`，
/// DocChunker.kt 按段落贪心装箱）。这里按任务口径升级：
/// - **标题识别**：markdown #、HTML h1-h3、纯文本首行都能成为候选标题
///   （识别在 doc_parsers.dart，本类只消费块流）；
/// - **正文分段装箱**：按 [DocImporterConfig.maxChars] 上限装箱，单段超限在
///   句末断开（DocChunker.kt:71-80 的断点策略原样移植）；
/// - **长度下限**：空壳候选（纯标题/残渣）丢弃；
/// - **去重**：内容指纹（规范化后 FNV-1a）单次导入内去重；跨导入/跨设备去重
///   与命中评测由 app 层拿 [NoteCandidate.hash] 自行判。
library;

import 'dart:convert';

import 'doc_parsers.dart';

/// 笔记候选结构的当前版本（K-7）。候选一旦落库、或随 ZIP 迁移导入器跨设备走，
/// schemaVersion 是唯一可靠的兼容判据——改字段先改版本。
const int noteCandidateSchemaVersion = 1;

/// 一条笔记候选：文档导入的产出，等待 app 层确认/策略入库为 Note。
/// 刻意不复用 kb_models.Note：候选没有 id/tags/enabled，是入库前置形态，
/// 入库时由 app 层生成 id、合并标签。
class NoteCandidate {
  const NoteCandidate({
    required this.title,
    required this.content,
    required this.sourceDoc,
    required this.hash,
    this.schemaVersion = noteCandidateSchemaVersion,
  });

  /// 候选标题：解析器认出的文档内标题；无标题时是兜底编号（见
  /// [DocImporter.importBlocks] 尾部）。
  final String title;

  /// 候选正文（原文搬运，导入层不做任何改写）。
  final String content;

  /// 来源文档名——知识库「来源追踪」的第一环，命中评测时按它回溯原文档。
  final String sourceDoc;

  /// 内容指纹（规范化后 FNV-1a 32 位，hex）。用途：单次导入内去重 +
  /// 跨导入去重/命中评测钩子的稳定 key（app 层用）。
  final String hash;

  /// 候选结构版本（K-7）。
  final int schemaVersion;

  @override
  String toString() =>
      'NoteCandidate(v$schemaVersion, $title, ${content.length}字, hash=$hash)';
}

/// 切分参数。默认值对齐 legacy 的实测结论，注释里给出处。
class DocImporterConfig {
  const DocImporterConfig({
    this.minChars = 10,
    this.maxChars = 600,
    this.maxCandidates = 2000,
    this.titleMaxChars = 120,
  });

  /// 正文下限：低于它的候选是空壳（纯标题/残渣），丢弃。
  final int minChars;

  /// 正文上限，超过装箱断开。600 沿用 legacy CHUNK_CHARS（DocImport.kt:43 的
  /// 实测：600 汉字 ≈ 600 token，一条命中 = 一个论点而不是一章书）。
  final int maxChars;

  /// 单文档候选上限，纯内存护栏（legacy MAX_CHUNKS = 2000，DocImport.kt:53——
  /// 超限静默截断，legacy 同款只取前 N 段）。
  final int maxCandidates;

  /// 标题上限：超长标题截断（legacy nameForUrl 取 120，DocImport.kt:195）。
  final int titleMaxChars;
}

/// 导入结果 + 丢弃对账。候选之外把**每一类静默丢弃**数出来：独立复核发现
/// 单行纯文本（整篇被当成标题块、无正文）产出 0 候选时上层看不到任何丢失
/// 痕迹——预览页要用这些计数如实告知「有 N 条内容没进来」，而不是无声无息。
class DocImportOutcome {
  const DocImportOutcome({
    required this.candidates,
    required this.droppedShort,
    required this.droppedTitleOnly,
    required this.droppedDuplicates,
    required this.droppedOverflow,
  });

  const DocImportOutcome.empty()
      : candidates = const [],
        droppedShort = 0,
        droppedTitleOnly = 0,
        droppedDuplicates = 0,
        droppedOverflow = 0;

  /// 通过下限与去重的候选。
  final List<NoteCandidate> candidates;

  /// 正文非空但短于 [DocImporterConfig.minChars] 被丢的草稿数（空壳纯噪音，
  /// 不计——那是解析层的空白残留，不是内容）。
  final int droppedShort;

  /// 只有标题、正文一行都没有的条数（单行纯文本整篇 + markdown 空节）。
  final int droppedTitleOnly;

  /// 内容指纹重复被去重丢掉的条数。
  final int droppedDuplicates;

  /// 超过 [DocImporterConfig.maxCandidates] 被截断的草稿数（legacy MAX_CHUNKS
  /// 同款静默截断——legacy 不计数，这里补上）。
  final int droppedOverflow;

  /// 有没有任何内容被丢过。
  bool get lostAnything =>
      droppedShort > 0 ||
      droppedTitleOnly > 0 ||
      droppedDuplicates > 0 ||
      droppedOverflow > 0;

  @override
  String toString() =>
      'DocImportOutcome(${candidates.length} 候选, 短正文丢 $droppedShort, '
      '仅标题丢 $droppedTitleOnly, 重复丢 $droppedDuplicates, 超上限丢 '
      '$droppedOverflow)';
}

/// 导入器：parse（doc_parsers.dart）→ importBlocks（本类）→ List<NoteCandidate>。
class DocImporter {
  DocImporter._(); // 纯静态工具类

  /// 从原始文本导入：猜格式（或用调用方指定的 [format]）→ 解析 → 切分。
  static List<NoteCandidate> importText({
    required String text,
    required String sourceDoc,
    DocTextFormat format = DocTextFormat.auto,
    DocImporterConfig config = const DocImporterConfig(),
  }) =>
      importTextWithStats(
        text: text,
        sourceDoc: sourceDoc,
        format: format,
        config: config,
      ).candidates;

  /// [importText] 的带对账版本：候选之外给出各类丢弃计数（见
  /// [DocImportOutcome]），供预览层如实透出「丢了什么」。
  static DocImportOutcome importTextWithStats({
    required String text,
    required String sourceDoc,
    DocTextFormat format = DocTextFormat.auto,
    DocImporterConfig config = const DocImporterConfig(),
  }) {
    final fmt = format == DocTextFormat.auto ? sniffFormat(text) : format;
    final parser = switch (fmt) {
      DocTextFormat.markdown => const MarkdownParser(),
      DocTextFormat.html => const HtmlParser(),
      DocTextFormat.plainText || DocTextFormat.auto => const PlainTextParser(),
    };
    return importBlocksWithStats(
      parser.parse(text),
      sourceDoc: sourceDoc,
      config: config,
    );
  }

  /// 格式嗅探：HTML → Markdown → 纯文本。
  ///
  /// HTML 判据照搬 legacy looksLikeHtml（DocImport.kt:199-204）：头 2048 字符里
  /// 出现 doctype/<html/<head/<body。Markdown 判据是头 2048 字符里有 ATX 标题行
  /// 或围栏——误判代价低（md 解析器对普通文本的行为接近纯文本解析）。
  static DocTextFormat sniffFormat(String text) {
    final head = text.length > 2048 ? text.substring(0, 2048) : text;
    final lower = head.trimLeft().toLowerCase();
    if (lower.startsWith('<!doctype html') ||
        lower.startsWith('<html') ||
        lower.contains('<head') ||
        lower.contains('<body')) {
      return DocTextFormat.html;
    }
    if (RegExp(r'^ {0,3}#{1,6}(\s|$)', multiLine: true).hasMatch(head) ||
        head.contains('```') ||
        head.contains('~~~')) {
      return DocTextFormat.markdown;
    }
    return DocTextFormat.plainText;
  }

  /// 块流 → 候选。公开出来是为了 PDF/EPUB 实现（app 层）解析完后直接复用切分。
  ///
  /// 装箱规则：标题块（level ≥ 1）刷新当前候选标题并结算前一段；正文块在
  /// 「并入会超 [DocImporterConfig.maxChars]」时先结算再装；单块自身超限走
  /// [hardSplit]（句末断开），除最后一片直接成稿，最后一片留给后续内容续装
  /// （续装片段沿用同一标题——同一节被切开的两半本就同源）。
  static List<NoteCandidate> importBlocks(
    List<ParsedBlock> blocks, {
    required String sourceDoc,
    DocImporterConfig config = const DocImporterConfig(),
  }) =>
      importBlocksWithStats(blocks, sourceDoc: sourceDoc, config: config)
          .candidates;

  /// [importBlocks] 的带对账版本：候选之外给出各类丢弃计数（见
  /// [DocImportOutcome]）。所有「静默丢弃」在这里都有账——上限护栏、长度
  /// 下限、仅标题、指纹去重——上层预览页照数如实告知，不再无声无息。
  static DocImportOutcome importBlocksWithStats(
    List<ParsedBlock> blocks, {
    required String sourceDoc,
    DocImporterConfig config = const DocImporterConfig(),
  }) {
    if (config.maxChars <= 0 ||
        config.minChars < 0 ||
        config.maxCandidates < 1 ||
        config.titleMaxChars < 1) {
      throw ArgumentError(
          'maxChars>0、minChars>=0、maxCandidates>=1、titleMaxChars>=1 必须成立');
    }

    // 第一遍：按标题装箱成 (title?, content) 草稿
    final drafts = <(String?, String)>[];
    final buffer = <String>[];
    var bufferLen = 0;
    var currentTitle = ''; // 空 = 尚无标题（文档开头/纯文本无标题的正文）

    var droppedShort = 0;
    var droppedTitleOnly = 0;
    var droppedOverflow = 0;
    // 当前标题下是否出现过任何正文（进过 emit 的都算，成不成稿另计）——
    // 换标题/收尾时还是 false 说明这一节只有标题没正文。
    var bodySeenSinceTitle = false;

    String? titleOrNull() => currentTitle.isEmpty ? null : currentTitle;

    void emit(String? title, String content) {
      final c = content.trim();
      if (c.isEmpty) return; // 空白残留：噪音不是内容，不进对账
      if (c.length < config.minChars) {
        droppedShort++; // 空壳（低于下限）丢弃——对账计数
        return;
      }
      if (drafts.length >= config.maxCandidates) {
        droppedOverflow++; // 上限护栏静默截断——legacy 不计数，这里补上
        return;
      }
      drafts.add((title, c));
    }

    /// 换标题/收尾时结算：老标题下没出现过任何正文 → 仅标题条目，丢。
    void settleTitle() {
      if (currentTitle.isNotEmpty && !bodySeenSinceTitle) droppedTitleOnly++;
    }

    void flushBuffer() {
      if (buffer.isEmpty) return;
      final content = buffer.join('\n');
      buffer.clear();
      bufferLen = 0;
      emit(titleOrNull(), content);
    }

    for (final block in blocks) {
      if (block.level >= 1) {
        flushBuffer();
        settleTitle();
        final t = block.text.trim();
        if (t.isNotEmpty) {
          // 空标题块不动 currentTitle（`#` 空行残留不该把标题洗掉）
          currentTitle = t.length > config.titleMaxChars
              ? t.substring(0, config.titleMaxChars)
              : t;
          bodySeenSinceTitle = false;
        }
        continue;
      }
      final text = block.text.trim();
      if (text.isEmpty) continue;
      bodySeenSinceTitle = true;
      if (bufferLen > 0 && bufferLen + 1 + text.length > config.maxChars) {
        flushBuffer();
      }
      if (text.length > config.maxChars) {
        final pieces = hardSplit(text, config.maxChars);
        for (var k = 0; k < pieces.length - 1; k++) {
          emit(titleOrNull(), pieces[k]);
        }
        buffer.add(pieces.last);
        bufferLen = pieces.last.length;
        continue;
      }
      bufferLen += (bufferLen > 0 ? 1 : 0) + text.length;
      buffer.add(text);
    }
    flushBuffer();
    settleTitle();

    // 第二遍：内容指纹去重（只比内容不比标题——同文不同标题大概率是复制粘贴
    // 残留，保留首次出现）；去重后再给无标题候选编号，保证 i/n 连续
    final seen = <String>{};
    final kept = <(String?, String, String)>[]; // (title?, content, hash)
    var droppedDuplicates = 0;
    for (final (title, content) in drafts) {
      final h = contentFingerprint(content);
      if (!seen.add(h)) {
        droppedDuplicates++;
        continue;
      }
      kept.add((title, content, h));
    }
    var untitledTotal = 0;
    for (final (title, _, _) in kept) {
      if (title == null) untitledTotal++;
    }
    var untitledIndex = 0;
    final candidates = [
      for (final (title, content, hash) in kept)
        NoteCandidate(
          title: title ??
              // 兜底标题沿用 legacy chunkTitle 格式 `文件名 (i/n)`
              // （DocImport.kt:465），但只给真正无标题的候选编号（n = 无标题
              // 候选数），有结构标题的不掺和。
              '$sourceDoc (${++untitledIndex}/$untitledTotal)',
          content: content,
          sourceDoc: sourceDoc,
          hash: hash,
        ),
    ];
    return DocImportOutcome(
      candidates: candidates,
      droppedShort: droppedShort,
      droppedTitleOnly: droppedTitleOnly,
      droppedDuplicates: droppedDuplicates,
      droppedOverflow: droppedOverflow,
    );
  }

  /// 把一个超长段落切成 ≤ [maxChars] 的片：优先句末（最后一个「句末符」落在
  /// 窗口后 1/4 处就断在那），其次空格（不切断英文单词），都没有就硬切。
  /// 策略原样移植 legacy DocChunker.kt:50-80。
  static List<String> hardSplit(String paragraph, int maxChars) {
    final out = <String>[];
    var start = 0;
    while (start < paragraph.length) {
      var end = start + maxChars;
      if (end >= paragraph.length) {
        final piece = paragraph.substring(start).trim();
        if (piece.isNotEmpty) out.add(piece);
        break;
      }
      final cut = _breakPoint(paragraph, start, end, maxChars);
      if (cut > start) end = cut;
      final piece = paragraph.substring(start, end).trim();
      if (piece.isNotEmpty) out.add(piece);
      start = end;
    }
    return out;
  }

  /// 句末符（中日英 + 换行）。'.' 会把 3.14 之类的数字切断——legacy 已接受的
  /// 代价（DocChunker.kt:15），保持一致不另立标准。
  static const String _sentenceEnders = '。！？!?；;.\n';

  static int _breakPoint(String s, int start, int end, int maxChars) {
    final floor = start + (maxChars * 3) ~/ 4;
    for (var i = end - 1; i >= floor; i--) {
      if (_sentenceEnders.contains(s[i])) return i + 1;
    }
    for (var i = end - 1; i >= floor; i--) {
      if (s[i] == ' ' || s[i] == '\t') return i + 1;
    }
    return end;
  }

  /// 内容指纹：规范化（小写 + 连续空白折叠成一个空格）后 FNV-1a 32 位 hex。
  ///
  /// 为什么不用 String.hashCode：它随 Dart VM 版本/平台漂移，跨设备去重（ZIP
  /// 迁移导入器）会失配；FNV-1a 是公开稳定算法，任何语言实现结果一致。
  /// 规范化只压空白和大小写、不动标点——宁可漏去重，不可误合并。
  static String contentFingerprint(String content) {
    final norm = content.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    var h = 0x811C9DC5;
    for (final b in utf8.encode(norm)) {
      h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }
}
