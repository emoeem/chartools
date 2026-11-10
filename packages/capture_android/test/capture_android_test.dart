import 'package:capture_android/capture_android.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 服务端 JSON 形状由 CaptureService.snapshotJson 决定：messages 只带
  // side/text，title/note 可省，provenance 缺省按 a11y。解析必须宽容。
  test('snapshot JSON 解析为 ChatSnapshot', () {
    const json = '{"title":"老板","note":"OCR 无法区分说话人",'
        '"provenance":"ocr",'
        '"messages":[{"side":"other","text":"明天记得交"},'
        '{"side":"me","text":"好的"}]}';
    final snap = CaptureAndroid.snapshotForTest(json);
    expect(snap, isNotNull);
    expect(snap!.title, '老板');
    expect(snap.provenance, Provenance.ocr);
    expect(snap.messages.length, 2);
    expect(snap.messages[0].side, 'other');
    expect(snap.messages[1].text, '好的');
    expect(snap.latestFrom, 'me');
  });

  test('null / 空串 / 非 JSON 容错', () {
    expect(CaptureAndroid.snapshotForTest(null), isNull);
    expect(CaptureAndroid.snapshotForTest(''), isNull);
    expect(
      () => CaptureAndroid.snapshotForTest('not json'),
      throwsA(isA<FormatException>()),
    );
  });
}
