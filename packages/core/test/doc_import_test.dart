/// doc_import（K-7 文档导入）的结构 torture 测试。
///
/// 每个纯文本解析器一组 torture（空文档/无标题/超长段落/中文内容/畸形标签），
/// 另有 DocImporter 的装箱/断句/去重/兜底标题与 PDF/EPUB 骨架的占位行为。
/// 断句与装箱策略对照 legacy：`core/kb/extract/DocChunker.kt`、
/// `core/kb/extract/DocImport.kt`（思路库，不是逐字复刻——标题识别/去重指纹是
/// 本实现的增量）。
library;

import 'dart:typed_data';

import 'package:chartools_core/src/persona_kb/doc_import/doc_importer.dart';
import 'package:chartools_core/src/persona_kb/doc_import/doc_parsers.dart';
import 'package:test/test.dart';

/// 把块流转成 (level, text) 记录列表比对——record 有结构等值，失败信息可读。
List<(int, String)> asTuples(List<ParsedBlock> blocks) =>
    blocks.map((b) => (b.level, b.text)).toList();

/// 骨架可实例化的探针子类（abstract 骨架本体不能直接 new）。
class _PdfProbe extends PdfImporter {}

class _EpubProbe extends EpubImporter {}

void main() {
  group('MarkdownParser torture', () {
    const p = MarkdownParser();

    test('空文档 / 纯空白 → 零块', () {
      expect(p.parse(''), isEmpty);
      expect(p.parse('   \n \t \n'), isEmpty);
    });

    test('无标题：普通段落按空行成块，软换行保留', () {
      expect(
        asTuples(p.parse('第一段甲\n第二段乙\n\n第三段丙')),
        [(0, '第一段甲\n第二段乙'), (0, '第三段丙')],
      );
    });

    test('超长单行段落：解析器不切分（切分是 DocImporter 的职责）', () {
      final got = p.parse('甲' * 3000);
      expect(got, hasLength(1));
      expect(got.single.level, 0);
      expect(got.single.text.length, 3000);
    });

    test('中文内容：标题层级/列表剥标记/行内装饰剥壳/围栏整块剥除', () {
      const md = '# 操作手册\n'
          '\n'
          '## 网调流程\n'
          '\n'
          '- 先看**安全边界**\n'
          '- 再查[回岗守则](https://example.com/x)\n'
          '\n'
          '```python\n'
          'print("这段不该出现")\n'
          '```\n'
          '\n'
          '正文里有 `行内代码` 和 *强调*。\n';
      expect(
        asTuples(p.parse(md)),
        [
          (1, '操作手册'),
          (2, '网调流程'),
          (0, '先看安全边界'),
          (0, '再查回岗守则'),
          (0, '正文里有 行内代码 和 强调。'),
        ],
      );
    });

    test('标题层级到 6 级；7 个 # 不是标题；# 后没空格不是标题', () {
      expect(
        asTuples(p.parse('###### 六级标题\n正文跟一段。')),
        [(6, '六级标题'), (0, '正文跟一段。')],
      );
      // CommonMark：# 后必须有空格
      expect(asTuples(p.parse('#hashtag 不是标题')), [(0, '#hashtag 不是标题')]);
      expect(asTuples(p.parse('####### 七个井号')), [(0, '####### 七个井号')]);
    });

    test('setext 下划线（=== / ---）在段后成标题', () {
      expect(
        asTuples(p.parse('标题一\n=====\n\n标题二\n---\n')),
        [(1, '标题一'), (2, '标题二')],
      );
    });

    test('畸形：围栏未闭合到 EOF——回收为正文（容错优先，不静默丢半篇）', () {
      expect(
        asTuples(p.parse('# 标\n\n```\n甲\n乙')),
        [(1, '标'), (0, '甲\n乙')],
      );
    });

    test('畸形：闭合的围栏连同信息串一起剥除，内容不进正文', () {
      expect(
        asTuples(p.parse('前文甲\n```js\nprint(1)\n```\n后文乙')),
        [(0, '前文甲'), (0, '后文乙')],
      );
    });

    test('列表与引用：有序/无序/缩进/嵌套引用都剥壳留字', () {
      expect(
        asTuples(p.parse('> 引用甲\n\n> > 嵌套乙\n\n  - 缩进丙\n1. 数字丁\n')),
        [(0, '引用甲'), (0, '嵌套乙'), (0, '缩进丙'), (0, '数字丁')],
      );
    });
  });

  group('HtmlParser torture', () {
    const p = HtmlParser();

    test('空文档 / 纯空白 → 零块', () {
      expect(p.parse(''), isEmpty);
      expect(p.parse('  \n  '), isEmpty);
    });

    test('无标题：p/div 只出正文块，没有任何标题块', () {
      final got = p.parse('<p>甲</p><div>乙</div>');
      expect(asTuples(got), [(0, '甲'), (0, '乙')]);
      expect(got.where((b) => b.level >= 1), isEmpty);
    });

    test('超长段落：解析器不切分，整段一个块', () {
      final got = p.parse('<p>${'长' * 3000}</p>');
      expect(got, hasLength(1));
      expect(got.single.text.length, 3000);
    });

    test('中文内容：h1-h2 结构 + 实体解码 + img 保留 alt + 行内标签透传', () {
      const html = '<h1>安全守则</h1>\n'
          '<p>第一条&nbsp;：&amp;转义&#x4E2D;文</p>\n'
          '<h2>网调</h2>\n'
          '<p>先<b>降速</b>再<img alt="截图">确认</p>';
      expect(
        asTuples(p.parse(html)),
        [
          (1, '安全守则'),
          (0, '第一条 ：&转义中文'),
          (2, '网调'),
          (0, '先降速再 截图 确认'),
        ],
      );
    });

    test('数字实体：十六进制与十进制都解码成中文', () {
      expect(asTuples(p.parse('<p>&#x4E2D;&#25991;</p>')), [(0, '中文')]);
    });

    test('畸形：未闭合 <p> 到 EOF 收段', () {
      expect(asTuples(p.parse('<p>未闭合段')), [(0, '未闭合段')]);
    });

    test('畸形：交错闭合 </div></b> 不中断解析，行内错位闭合被忽略', () {
      expect(asTuples(p.parse('<div><b>粗</div></b>尾')), [(0, '粗'), (0, '尾')]);
    });

    test('畸形：未闭合 <h1> 到下一个块标签为止收尾', () {
      expect(
        asTuples(p.parse('<h1>孤标题<p>正文</p>')),
        [(1, '孤标题'), (0, '正文')],
      );
    });

    test('畸形：<h2> 开在未闭合的 <h1> 里——先收外层再开新标题', () {
      expect(
        asTuples(p.parse('<h1>外<h2>内</h2>尾')),
        [(1, '外'), (2, '内'), (0, '尾')],
      );
    });

    test('畸形：属性值里带 >（引号内）不会提前截断标签', () {
      expect(asTuples(p.parse('<a title="x>y" href="u">链</a>')), [(0, '链')]);
    });

    test('畸形：杂散 < 不是标签（a < b、<3）按字面量保留', () {
      expect(asTuples(p.parse('<p>1 < 2 且 3 > 2</p>')), [(0, '1 < 2 且 3 > 2')]);
      expect(asTuples(p.parse('送花 <3 的人')), [(0, '送花 <3 的人')]);
    });

    test('script/style/head/title/svg 整块丢弃，注释丢弃', () {
      expect(
        asTuples(p.parse('<script>var a = 1;</script><!-- 注释 --><p>正文</p>')),
        [(0, '正文')],
      );
      // script 内容里的伪标签不参与解析
      expect(
        asTuples(p.parse(
            '<script>if (a<b) { x("<p>假</p>"); }</script><p>后</p>')),
        [(0, '后')],
      );
      expect(
        asTuples(p.parse(
            '<head><title>页题</title><meta charset="utf-8"></head>'
            '<body><p>身体</p></body>')),
        [(0, '身体')],
      );
    });
  });

  group('PlainTextParser torture', () {
    const p = PlainTextParser();

    test('空文档 / 纯空白 → 零块', () {
      expect(p.parse(''), isEmpty);
      expect(p.parse('  \n\t\n '), isEmpty);
    });

    test('短首行当标题（level 1），空行分段', () {
      expect(
        asTuples(p.parse('简短标题\n\n第一段正文内容。\n\n第二段正文内容。\n')),
        [(1, '简短标题'), (0, '第一段正文内容。'), (0, '第二段正文内容。')],
      );
    });

    test('无标题：首行超过 80 字不当地标题，落回正文', () {
      final got = p.parse('${'甲' * 120}\n\n正文乙');
      expect(got.where((b) => b.level >= 1), isEmpty);
      expect(asTuples(got), [(0, '甲' * 120), (0, '正文乙')]);
    });

    test('超长单行段落：整段一个块，不在此层切分', () {
      final got = p.parse('长' * 2000);
      expect(got, hasLength(1));
      expect(got.single.text.length, 2000);
    });

    test('中文 CRLF：\r\n 归一后标题/分段照常', () {
      expect(
        asTuples(p.parse('会议纪要\r\n第一行甲\r\n\r\n第二段乙\r\n')),
        [(1, '会议纪要'), (0, '第一行甲'), (0, '第二段乙')],
      );
    });

    test('标题后无空行直接接正文；开头全是空行也照常', () {
      expect(asTuples(p.parse('标题甲\n正文乙')), [(1, '标题甲'), (0, '正文乙')]);
      // 首个非空行就是标题——只有一行时它成为无正文的标题块，
      // 会被 DocImporter 的 minChars 丢掉（空壳），此处钉住解析层行为
      expect(asTuples(p.parse('   \n正文')), [(1, '正文')]);
    });
  });

  group('DocImporter.importBlocks', () {
    test('markdown 块流 → 候选带真实标题，K-7 三件套齐全', () {
      const md = '# 手册\n\n'
          '第一段正文写得足够长，稳过下限。\n\n'
          '## 附录\n\n'
          '第二段正文也够长，稳过下限。\n';
      final cands = DocImporter.importBlocks(
        const MarkdownParser().parse(md),
        sourceDoc: 'kb.md',
      );
      expect(cands, hasLength(2));
      expect(cands[0].title, '手册');
      expect(cands[0].content, '第一段正文写得足够长，稳过下限。');
      expect(cands[1].title, '附录');
      expect(cands[1].content, '第二段正文也够长，稳过下限。');
      for (final c in cands) {
        expect(c.schemaVersion, noteCandidateSchemaVersion); // K-7
        expect(c.sourceDoc, 'kb.md'); // 来源追踪
        expect(c.hash, DocImporter.contentFingerprint(c.content)); // 指纹可复算
      }
    });

    test('纯标题空壳被 minChars 丢弃（h1 后直接 h2，标题不单独成候选）', () {
      final cands = DocImporter.importBlocks(
        const [
          ParsedBlock(1, '标题'),
          ParsedBlock(0, '短'),
        ],
        sourceDoc: 'a.txt',
      );
      expect(cands, isEmpty);
    });

    test('单段超限：句末断开（断点在窗口后 1/4 处的最后一个句号），续片沿用标题', () {
      // 40 个甲 + 句号（下标 40）+ 15 个乙，共 56 字；maxChars=50 → 断在 41
      final cands = DocImporter.importBlocks(
        [
          const ParsedBlock(1, '主题'),
          ParsedBlock(0, '甲' * 40 + '。' + '乙' * 15),
        ],
        sourceDoc: 'a.txt',
        config: const DocImporterConfig(maxChars: 50),
      );
      expect(cands, hasLength(2));
      expect(cands[0].title, '主题');
      expect(cands[0].content, '甲' * 40 + '。');
      expect(cands[1].title, '主题'); // 同一节切开的续片，标题不重编
      expect(cands[1].content, '乙' * 15);
    });

    test('单段超限且无句末/空格：硬切到上限', () {
      final cands = DocImporter.importBlocks(
        [
          const ParsedBlock(1, '主题'),
          ParsedBlock(0, '乙' * 60),
        ],
        sourceDoc: 'a.txt',
        config: const DocImporterConfig(maxChars: 50),
      );
      expect(cands.map((c) => c.content).toList(), ['乙' * 50, '乙' * 10]);
    });

    test('去重：不同标题同内容只留首次出现', () {
      final cands = DocImporter.importBlocks(
        const [
          ParsedBlock(1, '甲'),
          ParsedBlock(0, '这一段正文完全一样哦'),
          ParsedBlock(1, '乙'),
          ParsedBlock(0, '这一段正文完全一样哦'),
        ],
        sourceDoc: 'a.txt',
      );
      expect(cands, hasLength(1));
      expect(cands.single.title, '甲');
    });

    test('maxCandidates 上限：静默截断（legacy MAX_CHUNKS 同策略）', () {
      final blocks = <ParsedBlock>[
        for (var i = 1; i <= 6; i++) ...[
          ParsedBlock(1, '标题$i'),
          ParsedBlock(0, '第$i段正文内容够长。'),
        ],
      ];
      final cands = DocImporter.importBlocks(
        blocks,
        sourceDoc: 'a.txt',
        config: const DocImporterConfig(maxCandidates: 3),
      );
      expect(cands, hasLength(3));
      expect(cands.map((c) => c.title).toList(), ['标题1', '标题2', '标题3']);
    });

    test('丢弃对账：短正文 / 仅标题 / 去重 / 超上限逐项计数', () {
      // 独立复核发现：静默丢弃（minChars、仅标题、截断、去重）上层原本看不到
      // 任何痕迹——单行纯文本整篇「消失」连预览都没得提示。importBlocks 的
      // 带对账版本把每一类都数出来。
      final outcome = DocImporter.importBlocksWithStats(
        const [
          ParsedBlock(1, '空节'), // 仅标题（下一个直接是标题）→ droppedTitleOnly
          ParsedBlock(1, '甲'),
          ParsedBlock(0, '太短'), // 2 字 < minChars 10 → droppedShort
          ParsedBlock(1, '乙'),
          ParsedBlock(0, '这一段正文完全一样哦'), // 保留
          ParsedBlock(1, '丙'),
          ParsedBlock(0, '这一段正文完全一样哦'), // 同文不同标题 → droppedDuplicates
        ],
        sourceDoc: 'a.txt',
      );
      expect(outcome.candidates, hasLength(1));
      expect(outcome.candidates.single.title, '乙');
      expect(outcome.droppedTitleOnly, 1);
      expect(outcome.droppedShort, 1);
      expect(outcome.droppedDuplicates, 1);
      expect(outcome.droppedOverflow, 0);
      expect(outcome.lostAnything, isTrue);
    });

    test('丢弃对账：超上限逐条计数（截断不再纯静默）', () {
      final blocks = <ParsedBlock>[
        for (var i = 1; i <= 4; i++) ...[
          ParsedBlock(1, '标题$i'),
          ParsedBlock(0, '第$i段正文内容够长。'),
        ],
      ];
      final outcome = DocImporter.importBlocksWithStats(
        blocks,
        sourceDoc: 'a.txt',
        config: const DocImporterConfig(maxCandidates: 2),
      );
      expect(outcome.candidates, hasLength(2));
      expect(outcome.droppedOverflow, 2);
    });

    test('非法 config 抛 ArgumentError', () {
      expect(
        () => DocImporter.importBlocks(
          const [ParsedBlock(0, '内容够长吗')],
          sourceDoc: 'a.txt',
          config: const DocImporterConfig(maxChars: 0),
        ),
        throwsArgumentError,
      );
    });
  });

  group('DocImporter.importText / sniffFormat', () {
    test('嗅探：doctype/html/head/body → html', () {
      expect(DocImporter.sniffFormat('<!DOCTYPE html><html><body>x'),
          DocTextFormat.html);
      expect(DocImporter.sniffFormat('  <html lang="zh"></html>'),
          DocTextFormat.html);
      // 误判口径与 legacy looksLikeHtml 一致（DocImport.kt:203）
      expect(DocImporter.sniffFormat('前文提到 <body 标签的处理'),
          DocTextFormat.html);
    });

    test('嗅探：ATX 标题行或围栏 → markdown，其余 → 纯文本', () {
      expect(DocImporter.sniffFormat('# 标题\n正文'), DocTextFormat.markdown);
      expect(DocImporter.sniffFormat('代码：\n```\nx\n```'),
          DocTextFormat.markdown);
      expect(DocImporter.sniffFormat('普通中文文本，没有标记。'),
          DocTextFormat.plainText);
    });

    test('端到端 html：h1 成候选标题', () {
      final cands = DocImporter.importText(
        text: '<html><body><h1>守则</h1><p>第一条内容够长一些哦。</p></body></html>',
        sourceDoc: 'a.html',
      );
      expect(cands, hasLength(1));
      expect(cands.single.title, '守则');
      expect(cands.single.content, '第一条内容够长一些哦。');
    });

    test('端到端 markdown：结构与来源/指纹一致，重复导入指纹稳定', () {
      const md = '# 手册\n\n第一段正文写得足够长，稳过下限。\n\n## 附录\n\n'
          '第二段正文也够长，稳过下限。\n';
      final cands = DocImporter.importText(text: md, sourceDoc: 'kb.md');
      expect(cands, hasLength(2));
      expect(cands[0].title, '手册');
      expect(cands[1].title, '附录');
      final again = DocImporter.importText(text: md, sourceDoc: 'kb.md');
      expect(again.map((c) => c.hash).toList(), cands.map((c) => c.hash).toList());
    });

    test('无标题兜底：沿用 legacy `文件名 (i/n)` 格式，只给无标题候选编号', () {
      // 首行 90 字（>80）不当标题 → 全文无标题；maxChars=50 把 90 字切开
      final cands = DocImporter.importText(
        text: '${'甲' * 90}\n\n${'乙' * 15}',
        sourceDoc: 'notes.txt',
        config: const DocImporterConfig(maxChars: 50),
      );
      expect(cands, hasLength(3));
      expect(cands[0].title, 'notes.txt (1/3)');
      expect(cands[1].title, 'notes.txt (2/3)');
      expect(cands[2].title, 'notes.txt (3/3)');
      expect(cands[0].content, '甲' * 50);
      expect(cands[1].content, '甲' * 40);
      expect(cands[2].content, '乙' * 15);
    });

    test('显式 format 覆盖嗅探：plainText 下 # 行按字面当标题', () {
      final forced = DocImporter.importText(
        text: '# 当标题的一行\n\n正文内容要够长才能入选哦。',
        sourceDoc: 'a.txt',
        format: DocTextFormat.plainText,
      );
      expect(forced.single.title, '# 当标题的一行');
      final auto = DocImporter.importText(
        text: '# 当标题的一行\n\n正文内容要够长才能入选哦。',
        sourceDoc: 'a.md',
      );
      expect(auto.single.title, '当标题的一行');
    });

    test('单行纯文本：候选 0 但对账显式透出「仅标题 1 条」，不再无声无息', () {
      // 独立复核实证：整篇被当标题块（≤80 rune 提标题、无正文）→ 候选 0，
      // legacy DocImport.kt 会产 1 个 `文件名 (1/1)` chunk——这里解析层行为
      // 被 torture 钉住不变，但 importTextWithStats 必须把这次丢弃数出来。
      final outcome = DocImporter.importTextWithStats(
        text: '今天记得买牛奶',
        sourceDoc: 'memo.txt',
      );
      expect(outcome.candidates, isEmpty);
      expect(outcome.droppedTitleOnly, 1);
      expect(outcome.droppedShort, 0);
      expect(outcome.lostAnything, isTrue);
      // 对照：同文本的无对账入口行为不变（解析层契约原样）。
      expect(
        DocImporter.importText(text: '今天记得买牛奶', sourceDoc: 'memo.txt'),
        isEmpty,
      );
    });
  });

  group('内容指纹（FNV-1a 32）', () {
    test('公开测试向量（跨语言一致性，ZIP 迁移跨设备去重靠它）', () {
      expect(DocImporter.contentFingerprint(''), '811c9dc5');
      expect(DocImporter.contentFingerprint('a'), 'e40c292c');
    });

    test('规范化：空白折叠 + 小写归一；中文不受影响', () {
      expect(
        DocImporter.contentFingerprint('Hello  World'),
        DocImporter.contentFingerprint('hello\nworld'),
      );
      expect(
        DocImporter.contentFingerprint('第一句 内容'),
        DocImporter.contentFingerprint('第一句\n内容'),
      );
      // 不动标点：宁可漏去重，不可误合并
      expect(
        DocImporter.contentFingerprint('走，出发。'),
        isNot(DocImporter.contentFingerprint('走，出发')),
      );
    });
  });

  group('PDF/EPUB 骨架（需要 pub 包，app 层决定引入）', () {
    test('PdfImporter.parseBytes 占位抛 UnsupportedError', () {
      expect(
        () => _PdfProbe().parseBytes(Uint8List(0)),
        throwsA(isA<UnsupportedError>()
            .having((e) => e.message, 'message', contains('pub'))),
      );
    });

    test('EpubImporter.parseBytes 占位抛 UnsupportedError', () {
      expect(
        () => _EpubProbe().parseBytes(Uint8List(0)),
        throwsA(isA<UnsupportedError>()
            .having((e) => e.message, 'message', contains('pub'))),
      );
    });
  });
}
