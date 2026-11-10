// 「粘贴分析」行解析器的单测：前缀全半角冒号、未知行归属、空行跳过。
import 'package:chartools_app/application/transcript_parser.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TranscriptParser.parse', () {
    test('全角冒号前缀决定 side', () {
      final p = TranscriptParser.parse('我：今天加班\n对方：辛苦了，几点回？');
      expect(p.messages, hasLength(2));
      expect(p.messages[0].side, 'me');
      expect(p.messages[0].text, '今天加班');
      expect(p.messages[1].side, 'other');
      expect(p.messages[1].text, '辛苦了，几点回？');
      expect(p.unattributed, 0);
    });

    test('半角冒号前缀同样识别，冒号后的空格不进步正文', () {
      final p = TranscriptParser.parse('我: hi there\n对方: ok');
      expect(p.messages, hasLength(2));
      expect(p.messages[0].side, 'me');
      expect(p.messages[0].text, 'hi there');
      expect(p.messages[1].side, 'other');
      expect(p.messages[1].text, 'ok');
      expect(p.unattributed, 0);
    });

    test('无法识别的行不归属（side 非 me/other）并计数', () {
      final p = TranscriptParser.parse('我：在吗\n（对方正在输入…）\n下午三点开会');
      expect(p.messages, hasLength(3));
      expect(p.messages[0].side, 'me');
      // 未知行既不是我也不是对方：downstream 渲染「发言人不明」。
      expect(p.messages[1].side, TranscriptParser.sideUnknown);
      expect(p.messages[1].sideKnown, isFalse);
      expect(p.messages[1].text, '（对方正在输入…）');
      expect(p.messages[2].side, TranscriptParser.sideUnknown);
      expect(p.messages[2].sideKnown, isFalse);
      expect(p.unattributed, 2);
    });

    test('前缀必须紧跟冒号：「我们」不算我', () {
      final p = TranscriptParser.parse('我们：都一起去\n我：好');
      expect(p.messages, hasLength(2));
      expect(p.messages[0].side, TranscriptParser.sideUnknown);
      expect(p.messages[0].text, '我们：都一起去');
      expect(p.messages[1].side, 'me');
      expect(p.unattributed, 1);
    });

    test('空行与纯空白行跳过', () {
      final p = TranscriptParser.parse('我：a\n\n   \n\t\n对方：b\n');
      expect(p.messages, hasLength(2));
      expect(p.messages[0].side, 'me');
      expect(p.messages[1].side, 'other');
      expect(p.unattributed, 0);
    });

    test('Windows 剪贴板的 \\r\\n 与裸 \\r 都按换行拆', () {
      final p = TranscriptParser.parse('我：a\r\n对方：b\r我：c');
      expect(p.messages, hasLength(3));
      expect(p.messages.map((m) => m.side), ['me', 'other', 'me']);
      expect(p.unattributed, 0);
    });

    test('全部无法识别时逐行计为未归属', () {
      final p = TranscriptParser.parse('hello\nworld\n');
      expect(p.messages, hasLength(2));
      expect(p.unattributed, 2);
      expect(p.messages.every((m) => m.side == TranscriptParser.sideUnknown),
          isTrue);
    });

    test('空输入解析为空', () {
      final p = TranscriptParser.parse('');
      expect(p.isEmpty, isTrue);
      expect(p.messages, isEmpty);
      expect(p.unattributed, 0);
    });

    test('解析结果能原样进 ChatSnapshot（桌面来源）并给出稳定签名', () {
      final p = TranscriptParser.parse('我：a\n对方：b');
      final snapshot = ChatSnapshot(
        messages: p.messages,
        provenance: Provenance.desktop,
      );
      expect(snapshot.provenance, Provenance.desktop);
      expect(snapshot.latestFrom, 'other');
      expect(snapshot.signature(), 'me:a|other:b');
    });
  });
}
