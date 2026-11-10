import 'package:chartools_core/src/jev_client/stream_text.dart';
import 'package:test/test.dart';

/// 对拍旧仓库 `StreamTextTest.kt`。
///
/// 两步解包都跑在**每个** partial chunk 上，所以有趣的用例全是「输入停在
/// 半截」：半个字符串、半个转义、三条候选只到一条。都不许抛错——卡片上
/// 出现半句话好过回复中途崩溃。
void main() {
  group('传输层：delta 信封', () {
    test('OpenAI 风格信封被拆开，取出正文片段', () {
      expect(StreamText.delta('{"choices":[{"delta":{"content":"你"}}]}'), '你');
    });

    test('不带正文的块（收尾 finish_reason）返回 null', () {
      expect(
          StreamText.delta('{"choices":[{"finish_reason":"stop"}]}'), isNull);
      expect(StreamText.delta('{"choices":[{"delta":{}}]}'), isNull);
    });

    test('空 content 与空 choices 都不算有内容', () {
      // content 为空串时不产出空片段，否则卡片会闪一个空行。
      expect(
          StreamText.delta('{"choices":[{"delta":{"content":""}}]}'), isNull);
      expect(StreamText.delta('{"choices":[]}'), isNull);
    });

    test('非 JSON 与空串不抛错，返回 null', () {
      expect(StreamText.delta(''), isNull);
      expect(StreamText.delta('not json at all'), isNull);
    });

    test('delta 缺失时回退 message 字段', () {
      // 非流式实现有时把整条回复按同一信封送进来（stream_text.dart 的
      // `first['delta'] ?? first['message']`）。
      expect(
          StreamText.delta('{"choices":[{"message":{"content":"你"}}]}'), '你');
    });
  });

  group('格式层：累积文本的可见部分', () {
    test('写到一半的候选显示已有正文', () {
      // 半截字符串：引号还没闭合，已有正文原样上卡。
      expect(StreamText.visible('[{"strategy":"safe","text":"你好"'), '你好');
    });

    test('完成的候选一行一条', () {
      final raw = '[{"strategy":"safe","text":"一"},'
          '{"strategy":"forward","text":"二"},'
          '{"strategy":"angle","text":"三"}]';
      expect(StreamText.visible(raw), '一\n二\n三');
    });

    test('JSON 转义被解码', () {
      // 累积文本是 JSON 原文，所以输入里是字面的「反斜杠 + n」和
      // 「反斜杠 + 引号」；显示前要解码。
      expect(StreamText.visible('[{"text":"第一行\\n第二行"}]'), '第一行\n第二行');
      expect(StreamText.visible('[{"text":"他说\\"好\\""}]'), '他说"好"');
    });

    test('截断的转义不崩溃也不吞掉正文', () {
      // 半个反斜杠、半个 \u 转义：转义本身丢弃，已有正文保留。
      expect(StreamText.visible('[{"text":"abc\\'), 'abc');
      expect(StreamText.visible('[{"text":"abc\\u00'), 'abc');
    });

    test('非法的 \\u 十六进制同样只丢转义不丢正文', () {
      // stream_text.dart 的 int.tryParse 失败分支：转义读不完就停在原地。
      expect(StreamText.visible('[{"text":"abc\\uZZ"}]'), 'abc');
    });

    test('无视 JSON 格式的散文照样预览（无 text 字段时的回退）', () {
      expect(StreamText.visible('你好呀，最近怎么样'), '你好呀，最近怎么样');
    });

    test('什么都还没到就是空串', () {
      expect(StreamText.visible(''), '');
      expect(StreamText.visible('['), '');
    });

    test('散文里的方括号后仍从其后取预览', () {
      // 对齐 StreamText.kt:66 的 substringAfter('[')：回退先跳过第一个 '['
      // 再剥脚手架字符——这是参考实现的既定行为，钉住防走样。
      expect(StreamText.visible('你看 [1] 好'), '1] 好');
    });
  });
}
