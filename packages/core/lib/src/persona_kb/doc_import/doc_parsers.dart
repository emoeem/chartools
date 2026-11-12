/// 文档文本解析层（doc_import 的纯文本系）。
///
/// 定位：core 零第三方依赖，因此 legacy 里靠 jsoup / pdfbox / XmlPull 做的事
/// （旧仓库 `core/kb/extract/HtmlText.kt`、`PdfText.kt`、`Epub.kt`），这里只移植
/// 纯文本系的自写解析；PDF/EPUB 留骨架，**需要 pub 包，由 app 层决定引入**
/// （见文件尾的 [PdfImporter] / [EpubImporter]）。
///
/// 统一产出「块流」：标题块（level 1..6）与正文块（level 0），顺序即文档顺序。
/// 「块 → 笔记候选」的切分不在这里，在 DocImporter（doc_importer.dart）——
/// 解析与切分分离，两端各自可测，PDF/EPUB 将来的实现也能直接复用同一切分尾部。
library;

import 'dart:typed_data';

/// 解析器统一契约：原始文本 → 块流。
abstract interface class DocTextParser {
  List<ParsedBlock> parse(String raw);
}

/// 块流中的一块：[level] == 0 为正文段落，1..6 为标题层级（md # / HTML h1-h3）。
class ParsedBlock {
  const ParsedBlock(this.level, this.text);

  final int level;
  final String text;

  @override
  String toString() => 'ParsedBlock($level, ${text.length}字)';
}

/// 文本格式。[DocTextFormat.auto] 交给 DocImporter.sniffFormat 猜，
/// 调用方也可以显式指定跳过嗅探。
enum DocTextFormat { auto, markdown, html, plainText }

// ---------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------

/// Markdown 解析：识别 ATX 标题层级（#/##/…######）、setext 标题（===/---）、
/// 列表（剥掉标记保留内容）、围栏代码块（整段剥除）与行内装饰（粗体/斜体/
/// 行内代码/链接图片剥壳留字）。
///
/// 与 legacy 的差异：旧仓库把 Markdown 当纯文本原样保留（PlainText.kt:14-17 的
/// 取舍——他们的产物直接喂模型）。这里产出的是**笔记候选**：标题要当候选标题、
/// 代码块对检索是噪声，所以按任务要求反向处理：结构识别 + 装饰剥除。
///
/// 已知简化（都不影响笔记用途，torture 测试里逐条钉住行为）：
/// - 4 空格缩进代码块不识别——中文纯文本里缩进太常见，误伤面大；
/// - 表格行当普通正文；
/// - 引用内的 setext 不识别（剥完 `>` 后只按 ATX/列表再识别一层）。
class MarkdownParser implements DocTextParser {
  const MarkdownParser();

  static final RegExp _atxRe = RegExp(r'^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$');
  static final RegExp _listRe = RegExp(r'^ {0,3}(?:[-*+]|\d{1,9}[.)])[ \t]+(.*)$');
  static final RegExp _quoteRe = RegExp(r'^ {0,3}>[ \t]?(.*)$');
  static final RegExp _setextEqRe = RegExp(r'^ {0,3}=+$');
  static final RegExp _setextDashRe = RegExp(r'^ {0,3}-+$');
  static final RegExp _fenceOpenRe = RegExp(r'^ {0,3}(`{3,}|~{3,})');
  static final RegExp _closingHashesRe = RegExp(r'[ \t]+#+[ \t]*$');

  @override
  List<ParsedBlock> parse(String raw) {
    final lines = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final out = <ParsedBlock>[];

    final para = <String>[]; // 当前段落积累的行（软换行，空行成段）
    String? fenceChar; // 打开的围栏字符（` 或 ~），null = 不在围栏里
    var fenceLen = 0;
    final fenceBuf = <String>[]; // 围栏内容；未闭合时回收成正文（见函数尾）

    void flushPara() {
      if (para.isEmpty) return;
      final t =
          para.map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');
      para.clear();
      if (t.isNotEmpty) out.add(ParsedBlock(0, t));
    }

    void emitHeading(int level, String text) {
      var t = stripMarkdownInline(text).trim();
      // CommonMark 允许标题收尾井号：`## 标题 ##` → 「标题」
      t = t.replaceAll(_closingHashesRe, '').trim();
      if (t.isNotEmpty) out.add(ParsedBlock(level, t));
    }

    for (final line in lines) {
      // —— 围栏内：只找闭合行（trim 后 ≥ 开头长度、全是同一字符）——
      // 注意必须先于空行分支：围栏内的空行是代码内容，不是段落边界
      if (fenceChar != null) {
        final t = line.trim();
        final closed =
            t.length >= fenceLen && t.split('').every((c) => c == fenceChar);
        if (closed) {
          fenceChar = null;
          fenceLen = 0;
        } else {
          fenceBuf.add(line);
        }
        continue;
      }

      // 空行 = 段落边界（否则空行会被当正文行积累，跨空行并成一块）
      if (line.trim().isEmpty) {
        flushPara();
        continue;
      }

      final fenceOpen = _fenceOpenRe.firstMatch(line);
      if (fenceOpen != null) {
        flushPara();
        final marker = fenceOpen[1]!;
        fenceChar = marker[0];
        fenceLen = marker.length;
        fenceBuf.clear();
        continue;
      }

      // ATX 标题：# 后必须有空格（`#话题` 不是标题，CommonMark 同款规则）
      final atx = _atxRe.firstMatch(line);
      if (atx != null) {
        flushPara();
        emitHeading(atx[1]!.length, atx[2] ?? '');
        continue;
      }

      // setext 下划线：仅当段落已有内容（CommonMark）；`---` 在段后优先当 h2，
      // 段前（para 空）落到下面的水平线分支被忽略
      if (para.isNotEmpty && _setextEqRe.hasMatch(line)) {
        emitHeading(1, para.removeLast());
        continue;
      }
      if (para.isNotEmpty && _setextDashRe.hasMatch(line)) {
        emitHeading(2, para.removeLast());
        continue;
      }

      // 水平线：同字符（*/-/_）与空格组成、非空 ≥3 个，整行忽略
      final trimmed = line.trim();
      final isHr = trimmed.length >= 3 &&
          (trimmed.split('').every((c) => c == '*' || c == ' ') ||
              trimmed.split('').every((c) => c == '-' || c == ' ') ||
              trimmed.split('').every((c) => c == '_' || c == ' '));
      if (isHr) {
        flushPara();
        continue;
      }

      // 列表项：剥标记，每项自成一块（候选正文按行合并，视觉不变）
      final list = _listRe.firstMatch(line);
      if (list != null) {
        flushPara();
        final item = stripMarkdownInline(list[1]!).trim();
        if (item.isNotEmpty) out.add(ParsedBlock(0, item));
        continue;
      }

      // 引用：剥掉全部 `>` 前缀，再按 ATX/列表识别一次（简化：不识别 setext）
      var stripped = line;
      var wasQuote = false;
      while (true) {
        final q = _quoteRe.firstMatch(stripped);
        if (q == null) break;
        stripped = q[1]!;
        wasQuote = true;
      }
      if (wasQuote) {
        if (stripped.trim().isEmpty) continue;
        final qAtx = _atxRe.firstMatch(stripped);
        if (qAtx != null) {
          flushPara();
          emitHeading(qAtx[1]!.length, qAtx[2] ?? '');
          continue;
        }
        final qList = _listRe.firstMatch(stripped);
        if (qList != null) {
          flushPara();
          final item = stripMarkdownInline(qList[1]!).trim();
          if (item.isNotEmpty) out.add(ParsedBlock(0, item));
          continue;
        }
        para.add(stripMarkdownInline(stripped));
        continue;
      }

      para.add(stripMarkdownInline(line));
    }

    flushPara();
    // 意图标注（畸形容错优先于规范保真）：围栏没闭合就到 EOF，多半是用户多敲了
    // 一个 ```；按 CommonMark 应把剩余全当代码丢掉，但笔记导入丢半篇最伤——
    // 回收为正文。
    if (fenceChar != null) {
      final t =
          fenceBuf.map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');
      if (t.isNotEmpty) out.add(ParsedBlock(0, t));
    }
    return out;
  }

  /// 剥行内装饰：图片取 alt、链接取文字、自动链接取网址、粗斜体/行内代码取内容。
  /// 意图标注：中文正文里 `` ` ``、`*`、`_` 极少裸出现，误伤可忽略；真正需要保留
  /// 这些字面量的场景（代码）已被围栏剥除。图片正则在链接之前——否则
  /// `![alt](u)` 会被链接正则吃掉感叹号。
  /// 实现：必须用 replaceAllMapped 取分组——Dart 的 String.replaceAll 不展开
  /// `$1`（ torture 测试钉过这个坑）。
  static final RegExp _imgRe = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
  static final RegExp _linkRe = RegExp(r'\[([^\]]*)\]\([^)]*\)');
  static final RegExp _autoLinkRe = RegExp(r'<(https?://[^>\s]+)>');
  static final RegExp _boldStarRe = RegExp(r'\*\*([^*]+)\*\*');
  static final RegExp _boldUnderRe = RegExp(r'__([^_]+)__');
  static final RegExp _italicStarRe = RegExp(r'\*([^*\n]+)\*');
  static final RegExp _italicUnderRe = RegExp(r'_([^_\n]+)_');
  static final RegExp _codeRe = RegExp(r'`([^`\n]+)`');

  static String stripMarkdownInline(String s) {
    var t = s;
    t = t.replaceAllMapped(_imgRe, (m) => m[1]!); // 图片 → alt
    t = t.replaceAllMapped(_linkRe, (m) => m[1]!); // 链接 → 文字
    t = t.replaceAllMapped(_autoLinkRe, (m) => m[1]!); // 自动链接 → 网址
    t = t.replaceAllMapped(_boldStarRe, (m) => m[1]!); // **粗体**
    t = t.replaceAllMapped(_boldUnderRe, (m) => m[1]!); // __粗体__
    t = t.replaceAllMapped(_italicStarRe, (m) => m[1]!); // *斜体*
    t = t.replaceAllMapped(_italicUnderRe, (m) => m[1]!); // _斜体_
    t = t.replaceAllMapped(_codeRe, (m) => m[1]!); // `行内代码`
    return t;
  }
}

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------

/// HTML 解析（零依赖手写，不做完整 DOM）。
///
/// legacy 用 jsoup（HtmlText.kt——jsoup 能吞任意畸形 HTML）。这里用**状态机式
/// 扫描**替代：逐字符走，遇到「像标签的 <」就按标签处理，不像就当字面量。
/// 畸形标签（未闭合、交错闭合、属性里带 >、杂散 <、引号未闭合）天然不会中断
/// 解析——这正是 legacy 选 jsoup 而不是 XML pull parser 的原因（HtmlText.kt:10-14），
/// 本实现用零依赖达成同一目标。
///
/// 结构：h1-h3 → 标题块（DocImporter 的候选边界，任务口径只认到 h3）；h4-h6 与
/// 块级标签 → 段落边界；行内标签透传文字；script/style/head/title/noscript/svg/
/// iframe 整块丢弃（legacy HtmlText.kt:22 同集合，另加 svg/iframe——它们内部的
/// 文本节点不是正文）；img 保留 alt 文字（legacy HtmlText.kt:38-44 同款）；
/// 实体解码做常用命名集 + 数字实体。
class HtmlParser implements DocTextParser {
  const HtmlParser();

  /// 打开后要跳到对应闭合标签的元素（内容不是正文）。
  static const Set<String> _skipContent = {
    'script', 'style', 'head', 'title', 'noscript', 'svg', 'iframe',
  };

  /// void 元素：只有标签没有内容，跳过标签本身即可。
  static const Set<String> _voidTags = {
    'meta', 'link', 'base', 'area', 'col', 'embed', 'input', 'param',
    'source', 'track', 'wbr',
  };

  /// 块级标签：出现即断段。h4-h6 在此按任务口径只当段落边界（不当候选边界）。
  static const Set<String> _blockTags = {
    'p', 'div', 'li', 'ul', 'ol', 'tr', 'td', 'th', 'table', 'thead', 'tbody',
    'tfoot', 'blockquote', 'pre', 'section', 'article', 'aside', 'header',
    'footer', 'nav', 'main', 'figure', 'figcaption', 'dl', 'dt', 'dd', 'hr',
    'form', 'body', 'html', 'caption', 'h4', 'h5', 'h6', 'br',
  };

  static const Set<String> _headingTags = {'h1', 'h2', 'h3'};

  @override
  List<ParsedBlock> parse(String raw) {
    final s = raw;
    final out = <ParsedBlock>[];
    final text = StringBuffer();
    var headingLevel = 0; // 0 = 无打开的标题；1..3 = h1..h3
    final headingText = StringBuffer();

    void flushText() {
      if (text.length == 0) return;
      final t = _normalize(_decode(text.toString()));
      text.clear();
      if (t.isNotEmpty) out.add(ParsedBlock(0, t));
    }

    void endHeading() {
      if (headingLevel == 0) return;
      final lvl = headingLevel;
      headingLevel = 0;
      final t = _normalize(_decode(headingText.toString()));
      headingText.clear();
      if (t.isNotEmpty) out.add(ParsedBlock(lvl, t));
    }

    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c != '<') {
        (headingLevel > 0 ? headingText : text).write(c);
        i++;
        continue;
      }
      // 注释：整个丢弃（含未闭合到 EOF 的情况）
      if (s.startsWith('<!--', i)) {
        final end = s.indexOf('-->', i + 4);
        i = end < 0 ? s.length : end + 3;
        continue;
      }
      // doctype / 处理指令：跳到 '>'
      if (s.startsWith('<!', i) || s.startsWith('<?', i)) {
        final end = s.indexOf('>', i + 2);
        i = end < 0 ? s.length : end + 1;
        continue;
      }
      final isClose = i + 1 < s.length && s.codeUnitAt(i + 1) == 0x2F; // '/'
      final nameIdx = isClose ? i + 2 : i + 1;
      if (nameIdx < s.length && _isAlpha(s[nameIdx])) {
        final tag = _scanTag(s, i, isClose);
        if (tag != null) {
          i = tag.end;
          final name = tag.name;

          // —— 闭合标签 ——
          if (tag.isClose) {
            if (_headingTags.contains(name)) {
              // 不校验层级匹配：畸形的 </h2> 收掉打开的 h1 也算收尾
              endHeading();
            } else if (_blockTags.contains(name)) {
              endHeading();
              flushText();
            }
            // 行内闭合标签（</b>、错位的 </span>）：忽略
            continue;
          }

          // —— void 元素：无内容，跳过标签本身 ——
          if (_voidTags.contains(name)) continue;

          // —— 内容整体丢弃的元素：跳到对应闭合 ——
          // head 特例：很多真实网页没有 </head>，也要在 <body 处停，否则吞掉全文。
          if (_skipContent.contains(name) && !tag.selfClosing) {
            i = _skipToClose(s, i, name);
            continue;
          }

          // —— XHTML 式自闭合（<p/>、<br/>）：按一次断段处理 ——
          if (tag.selfClosing) {
            if (name == 'img') {
              _appendImgAlt(tag, headingText, text, headingLevel);
            } else {
              endHeading();
              flushText();
            }
            continue;
          }

          // —— h1-h3：候选边界（畸形嵌套 <h1>…<h2>：先收掉外层再开新的）——
          if (_headingTags.contains(name)) {
            endHeading();
            flushText();
            headingLevel = int.parse(name.substring(1));
            continue;
          }

          if (name == 'img') {
            _appendImgAlt(tag, headingText, text, headingLevel);
            continue;
          }

          if (name == 'br') {
            // 意图标注：br 是软换行——标题里并成空格（别把一个标题撕成两块），
            // 正文里断段（块内容按行合并，视觉等价于换行）
            if (headingLevel > 0) {
              headingText.write(' ');
            } else {
              flushText();
            }
            continue;
          }

          if (_blockTags.contains(name)) {
            endHeading();
            flushText();
            continue;
          }

          // 其余一律当行内标签（b/i/span/a/code/…）：透传内部文字
          continue;
        }
      }
      // 不像标签的 <（如 `a < b`、`<3`）：当字面量
      (headingLevel > 0 ? headingText : text).write(c);
      i++;
    }
    endHeading();
    flushText();
    return out;
  }

  /// img 的 alt 文字进当前缓冲，前后留空格隔开正文（legacy HtmlText.kt:41-43 同款）。
  void _appendImgAlt(
      _HtmlTag tag, StringBuffer headingText, StringBuffer text, int headingLevel) {
    final alt = tag.attrs['alt']?.trim() ?? '';
    if (alt.isNotEmpty) {
      (headingLevel > 0 ? headingText : text).write(' $alt ');
    }
  }

  /// 从 [lt]（'<' 处）扫完一个标签，引号内的 '>' 不算标签结束。
  /// 返回 null 表示这根本不是标签（没有 > 或引号未闭合），调用方按字面量处理。
  static _HtmlTag? _scanTag(String s, int lt, bool isClose) {
    var j = lt + 1 + (isClose ? 1 : 0);
    final nameStart = j;
    while (j < s.length && _isNameChar(s[j])) {
      j++;
    }
    if (j == nameStart) return null;
    final name = s.substring(nameStart, j).toLowerCase();
    while (j < s.length) {
      final ch = s[j];
      if (ch == '"' || ch == "'") {
        final q = s.indexOf(ch, j + 1);
        if (q < 0) return null; // 引号没闭合：整个 < 按字面量
        j = q + 1;
        continue;
      }
      if (ch == '>') {
        final src = s.substring(lt, j + 1);
        return _HtmlTag(
          name: name,
          end: j + 1,
          isClose: isClose,
          selfClosing: src.endsWith('/>'),
          attrs: _parseAttrs(src),
        );
      }
      j++;
    }
    return null; // 没有 '>'：整个剩余按字面量
  }

  static final RegExp _attrRe = RegExp(
      r'''([a-zA-Z_][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))''');

  /// 从标签源码里抠属性（目前只有 img@alt 用到；够用即止，不做完整属性语法）。
  static Map<String, String> _parseAttrs(String tagSrc) {
    final out = <String, String>{};
    for (final m in _attrRe.allMatches(tagSrc)) {
      out[m[1]!.toLowerCase()] = (m[2] ?? m[3] ?? m[4] ?? '').trim();
    }
    return out;
  }

  /// 跳过 [name] 的原始内容，停在对应闭合标签之后。
  static int _skipToClose(String s, int from, String name) {
    final closeRe = RegExp('</$name\\s*>', caseSensitive: false);
    final m = closeRe.firstMatch(s.substring(from));
    if (m != null) return from + m.end;
    if (name == 'head') {
      final bodyIdx = s.toLowerCase().indexOf('<body', from);
      if (bodyIdx >= 0) return bodyIdx;
    }
    return s.length; // 闭合缺失（如 <script> 吞到底）：余下全丢
  }

  static final RegExp _entityRe =
      RegExp(r'&(#[xX][0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z][a-zA-Z0-9]{0,9});');

  static const Map<String, String> _namedEntities = {
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': '\u00a0',
    'mdash': '—',
    'ndash': '–',
    'hellip': '…',
    'ldquo': '“',
    'rdquo': '”',
    'lsquo': '‘',
    'rsquo': '’',
    'copy': '©',
    'reg': '®',
    'trade': '™',
    'middot': '·',
    'times': '×',
  };

  /// 实体解码：常用命名集 + 数字/十六进制。未知实体保留原样（宁可带个 &xxx;
  /// 也不猜错）；非法码点与孤代理项同样保留原样。只在剥完标签后的文本缓冲上
  /// 跑一遍、不重扫——解码产物不可能再变成标签。
  static String _decode(String t) {
    return t.replaceAllMapped(_entityRe, (m) {
      final body = m[1]!;
      if (body.startsWith('#')) {
        final cp = (body[1] == 'x' || body[1] == 'X')
            ? int.parse(body.substring(2), radix: 16)
            : int.parse(body.substring(1));
        if (cp <= 0 || cp > 0x10ffff || (cp >= 0xD800 && cp <= 0xDFFF)) {
          return m[0]!;
        }
        return String.fromCharCode(cp);
      }
      return _namedEntities[body] ?? m[0]!;
    });
  }

  /// HTML 空白归一：连续空白并成一个空格再去首尾（浏览器对正文的同款语义）。
  static String _normalize(String t) =>
      t.replaceAll(RegExp(r'\s+'), ' ').trim();

  static bool _isAlpha(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
  }

  static bool _isNameChar(String c) {
    final u = c.codeUnitAt(0);
    return _isAlpha(c) ||
        (u >= 0x30 && u <= 0x39) || // 0-9
        u == 0x2D || // -
        u == 0x5F || // _
        u == 0x3A || // :
        u == 0x2E; // .
  }
}

/// _scanTag 的产物。
class _HtmlTag {
  const _HtmlTag({
    required this.name,
    required this.end,
    required this.isClose,
    required this.selfClosing,
    required this.attrs,
  });

  final String name;
  final int end; // 标签结束后的下一个字符下标
  final bool isClose;
  final bool selfClosing;
  final Map<String, String> attrs;
}

// ---------------------------------------------------------------------------
// 纯文本
// ---------------------------------------------------------------------------

/// 纯文本解析：首个非空行当标题（够短才当），空行分段。
///
/// legacy 完全不认标题（chunk 一律叫 `文件名 (i/n)`，DocImport.kt:465）；这里按
/// 任务要求把首行提为候选标题。80 字上限是防误判：一篇没有空行的中文文档，
/// 首行动辄几百字，那是正文不是标题—— torture 测试钉住这条边界。
class PlainTextParser implements DocTextParser {
  const PlainTextParser();

  /// 首行超过这么多字符（runes，中文一字一符）就不当标题。
  static const int maxTitleRunes = 80;

  @override
  List<ParsedBlock> parse(String raw) {
    final lines =
        raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

    // 首个非空行 → 标题（level 1，与 markdown 一级标题同待遇）
    var idx = 0;
    while (idx < lines.length && lines[idx].trim().isEmpty) {
      idx++;
    }
    final out = <ParsedBlock>[];
    var bodyStart = 0;
    if (idx < lines.length && lines[idx].trim().runes.length <= maxTitleRunes) {
      out.add(ParsedBlock(1, lines[idx].trim()));
      bodyStart = idx + 1;
    }

    // 空行（只含空白）分段；段内行保留换行
    final paraLines = <String>[];
    void flushPara() {
      if (paraLines.isEmpty) return;
      final t = paraLines
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .join('\n');
      paraLines.clear();
      if (t.isNotEmpty) out.add(ParsedBlock(0, t));
    }

    for (var k = bodyStart; k < lines.length; k++) {
      if (lines[k].trim().isEmpty) {
        flushPara();
      } else {
        paraLines.add(lines[k]);
      }
    }
    flushPara();
    return out;
  }
}

// ---------------------------------------------------------------------------
// 二进制容器：PDF / EPUB 骨架（core 不实现，等 app 层引 pub 包）
// ---------------------------------------------------------------------------

/// PDF 导入器——**骨架占位，core 不实现**。
///
/// 为什么：PDF 是二进制容器（压缩流 + 字体子集 + 编码表），纯 Dart 手写解码不
/// 现实；legacy 也一样引 pdfbox（旧仓库 `core/kb/extract/PdfText.kt`）。core 保持
/// 零第三方依赖，**需要 pub 包（如 `pdf_text`、`printing`），由 app 层决定引入**：
/// app 层子类化本骨架 override [parseBytes]，提取出纯文本后直接调
/// DocImporter.importText / importBlocks 复用标题识别与切分。
///
/// app 层实现时抄 legacy PdfText.kt 的三条经验：
/// 1. 解析要喂**字节/文件**，不要流——pdfbox 的流式入口会把整包缓冲进堆；
/// 2. 先探文字层（legacy：非空白字符 < 100 判为扫描件），扫描件走 OCR，且 OCR
///    页数必须有上限（legacy MAX_OCR_PAGES = 20——500 页扫描书是小时级任务，
///    不是笔记）；
/// 3. 加密 PDF（InvalidPasswordException）要翻译成一句人话，不是抛栈。
abstract class PdfImporter {
  const PdfImporter();

  /// PDF 字节 → 块流。占位实现直接抛 [UnsupportedError]。
  List<ParsedBlock> parseBytes(Uint8List bytes) => throw UnsupportedError(
      'PDF 解析需要 pub 包（pdf_text / printing 等），由 app 层决定引入；core 保持零依赖');
}

/// EPUB 导入器——**骨架占位，core 不实现**。
///
/// 为什么：EPUB 是 ZIP 容器，读 ZIP 也要 pub 包（如 `archive`；dart:io 自带
/// zlib，自写中央目录解析也可行，但按任务口径留给 app 层选择）。legacy 的走法
/// 见旧仓库 `core/kb/extract/Epub.kt`：**阅读顺序 = spine**——
/// META-INF/container.xml → OPF 包文档 → manifest（id→href）→ spine（idref 顺序）；
/// 直接按 ZIP 条目顺序走会把封面/导航排到正文前。
///
/// app 层实现建议：archive 解 ZIP → 按 spine 顺序取 .xhtml 条目 → 逐条喂
/// [HtmlParser]（EPUB 内容文档就是 HTML）→ 合并块流 → DocImporter.importBlocks。
abstract class EpubImporter {
  const EpubImporter();

  /// EPUB 字节 → 块流。占位实现直接抛 [UnsupportedError]。
  List<ParsedBlock> parseBytes(Uint8List bytes) => throw UnsupportedError(
      'EPUB 解析需要 pub 包（archive 等），由 app 层决定引入；core 保持零依赖');
}
