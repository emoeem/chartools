import 'package:capture_android/capture_android.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/services.dart';
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

  // fix(kimi-review #2)：重放请求的两侧契约。Kotlin 侧 ConfigureReplayTest
  // 钳发送单元（control 通道 + 'requestConfigure'、fire-and-forget）；这里钳
  // 接收端——通道/方法名字面量与 Kotlin 常量（CaptureService.kt:54/59/68）
  // 同名同值，分发语义经 [CaptureAndroid.handleControlMethodCall] 直测。
  //
  // 刻意不走真通道、不初始化 flutter_test binding：第 2 轮门禁实测，测试
  // 文件在加载期（group 注册期）初始化 binding 曾随 runner 的套件派生偶发
  // 「Connection closed before test suite loaded」。纯 Dart 缝让本套件在
  // 加载期零副作用；真通道挂接（_attachControlHandler → setMethodCallHandler）
  // 是用同一对常量的 3 行接线，通道/方法名任何一侧漂移都会被这里或 Kotlin
  // 测试咬住。
  group('requestConfigure 重放（control 通道，fix kimi-review #2）', () {
    test('通道与方法名与 Kotlin 侧常量同名同值', () {
      expect(CaptureAndroid.controlChannelName, 'capture_android/control');
      expect(CaptureAndroid.requestConfigureMethod, 'requestConfigure');
    });

    // fix(kimi-review #11)：防截屏开关的方法名两侧互钳——独立复核发现
    // handleControl 曾漏 'setSecure' 分支，Dart 恒收 notImplemented，开关
    // 永远停在关位。Kotlin 侧 SetSecureContractTest 钳同一个字面量。
    test('setSecure 方法名与 Kotlin 分支键同名同值', () {
      expect(CaptureAndroid.setSecureMethod, 'setSecure');
      expect(CaptureAndroid.controlChannelName, 'capture_android/control');
    });

    test('requestConfigure → 调重放回调', () async {
      var replays = 0;
      CaptureAndroid.onConfigureReplay = () async => replays++;
      addTearDown(() => CaptureAndroid.onConfigureReplay = null);

      await CaptureAndroid.handleControlMethodCall(
          const MethodCall(CaptureAndroid.requestConfigureMethod));

      expect(replays, 1);
    });

    test('回调为空时静默丢弃（与原生 fire-and-forget 对齐）', () async {
      CaptureAndroid.onConfigureReplay = null;

      // 不抛、不悬挂：Dart 未接住时服务侧本就不等待不重试。
      final reply = await CaptureAndroid.handleControlMethodCall(
          const MethodCall(CaptureAndroid.requestConfigureMethod));

      expect(reply, isNull);
    });

    test('未知方法按 null 应答，不抛 notImplemented', () async {
      CaptureAndroid.onConfigureReplay = () async {};

      final reply = await CaptureAndroid.handleControlMethodCall(
          const MethodCall('no_such_method'));

      expect(reply, isNull);
    });
  });
}
