import 'package:chartools_core/src/jev_client/json_slice.dart';
import 'package:test/test.dart';

/// 对拍旧仓库 `JsonSliceTest.kt`。
///
/// 模型被要求给 JSON 时，经常裹着散文或 markdown 围栏送回来；而候选回复
/// （`"text"` 字段）本身可能带花括号，所以「首个 `{` 切到最后一个 `}`」的切法
/// 必然切过头。切法必须按括号深度扫描，并忽略字符串字面量里的括号。
void main() {
  test('裸对象原样返回', () {
    expect(JsonSlice.firstObject('{"a":1}'), '{"a":1}');
  });

  test('markdown 围栏不挡切取', () {
    final reply = '```json\n{"answers":{"a":1}}\n```';
    expect(JsonSlice.firstObject(reply), '{"answers":{"a":1}}');
  });

  test('前后裹散文照样切中对象', () {
    // 文案与 Kotlin 逐字一致（这是模型会送的句子）。
    expect(JsonSlice.firstObject('好的，结果如下：{"a":1} 以上。'), '{"a":1}');
  });

  test('字符串里的花括号不提前结束对象', () {
    // 候选回复引用在 JSON 里且自带花括号：深度计数要跳过字符串字面量里的
    // 花括号，否则切点会被拖过真正的结尾。
    final reply = '{"text":"} 别这样 {","n":1}';
    expect(JsonSlice.firstObject(reply), reply);
  });

  test('字符串里的转义引号不会误开新字符串', () {
    // `\"` 不算字符串边界，切完必须还是整个对象。
    final reply = '{"text":"他说 \\"好\\" 了","n":1}';
    expect(JsonSlice.firstObject(reply), reply);
  });

  test('嵌套对象整体返回', () {
    final reply = '{"a":{"b":{"c":1}}}';
    expect(JsonSlice.firstObject(reply), reply);
  });

  test('只取第一个对象', () {
    expect(JsonSlice.firstObject('{"a":1} and {"b":2}'), '{"a":1}');
  });

  test('没有对象返回 null', () {
    // 拒答等纯文本回复：不能抛错，也不能把散文当 JSON。
    expect(JsonSlice.firstObject('抱歉，我无法判断。'), isNull);
  });

  test('未闭合的对象返回 null', () {
    expect(JsonSlice.firstObject('{"a":1'), isNull);
  });

  test('对象之前的孤立闭括号不干扰切取', () {
    // 深度保护（json_slice.dart 的 depth > 0 守卫）：散文里先冒出的 `}`
    // 既不是对象终点，也不能吃掉后面真正对象的起点。
    expect(JsonSlice.firstObject('不对 } {"a":1}'), '{"a":1}');
  });
}
