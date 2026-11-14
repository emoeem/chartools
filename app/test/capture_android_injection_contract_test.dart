/// M0 注入开关镜像（root-module-design.md §3.3-3/§4-M0）—— capture_android
/// 门面的调用契约测试（stub 通道断言 payload 键），与 Kotlin 侧
/// CaptureService.applyConfigureStatics / injectionEnabledOf 的解析语义互钳：
///
/// 1. configure 载荷恒带 `injectionEnabled` 键（缺省语义在 Kotlin 侧 = 空映射
///    = 全关；门面恒带键让既有推送都携带当前开关意图）。
/// 2. setInjectionEnabled 无底稿：只记录镜像、零通道调用（不发孤键载荷——
///    packages 键缺省 = 恒替换为空集，孤键载荷会清空采集白名单）；并入下次
///    configure 的载荷。
/// 3. setInjectionEnabled 有底稿：立即按同载荷重推一次 configure——载荷完整
///    （packages/blocked/ocrFallback/secure 原样）且 injectionEnabled 为新值。
/// 4. 通道不可用：MissingPluginException 原样抛给调用方兜底（与
///    canRequestNotifications 同款）。
///
/// 契约测试不走真通道：stub capture_android/control（套件加载期零 binding
/// 副作用的既有口径，见 capture_android_test.dart 的注释）。
library;

import 'package:capture_android/capture_android.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const controlChannel = MethodChannel('capture_android/control');
  final configureCalls = <MethodCall>[];

  setUp(() {
    CaptureAndroid.resetInjectionMirrorForTest();
    configureCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, (call) async {
      if (call.method == 'configure') configureCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, null);
  });

  Map<Object?, Object?> payloadOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  test('configure 载荷恒带 injectionEnabled 键，其余四键原样（契约键名逐字）', () async {
    await CaptureAndroid().configure(
      packages: {'com.tencent.mobileqq'},
      ocrFallback: true,
      blocked: {'com.unionpay'},
      secure: false,
    );

    expect(configureCalls, hasLength(1));
    final args = payloadOf(configureCalls.single);
    // 默认镜像为空映射 = 全关（fail-closed 缺省）。
    expect(args['injectionEnabled'], <String, bool>{});
    expect(args['packages'], ['com.tencent.mobileqq']);
    expect(args['ocrFallback'], true);
    expect(args['blocked'], ['com.unionpay']);
    expect(args['secure'], false);
  });

  test('setInjectionEnabled 无底稿：零通道调用，镜像并入下次 configure 载荷', () async {
    await CaptureAndroid()
        .setInjectionEnabled({'org.telegram.messenger': true});
    expect(configureCalls, isEmpty);

    await CaptureAndroid().configure(
      packages: {'org.telegram.messenger'},
      ocrFallback: false,
      blocked: {},
      secure: false,
    );
    expect(configureCalls, hasLength(1));
    expect(payloadOf(configureCalls.single)['injectionEnabled'],
        {'org.telegram.messenger': true});
  });

  test('setInjectionEnabled 有底稿：立即重推完整载荷，packages 不被清空', () async {
    // 底稿 = 采集页刚推过的完整配置。
    await CaptureAndroid().configure(
      packages: {'com.tencent.mobileqq', 'org.telegram.messenger'},
      ocrFallback: true,
      blocked: {'com.unionpay'},
      secure: true,
    );
    expect(configureCalls, hasLength(1));

    await CaptureAndroid()
        .setInjectionEnabled({'org.telegram.messenger': true});
    await pumpEventQueue();

    expect(configureCalls, hasLength(2));
    final args = payloadOf(configureCalls.last);
    expect(args['injectionEnabled'], {'org.telegram.messenger': true});
    // 重推是完整载荷：任何一键缺失都会在 Kotlin 侧顶掉真实状态
    // （packages 恒替换 / ocrFallback 缺省 false）。
    expect(args['packages'],
        ['com.tencent.mobileqq', 'org.telegram.messenger']);
    expect(args['blocked'], ['com.unionpay']);
    expect(args['ocrFallback'], true);
    expect(args['secure'], true);
  });

  test('setInjectionEnabled 空映射 = 全关，显式 false 原样下发', () async {
    await CaptureAndroid().configure(
      packages: {'org.telegram.messenger'},
      ocrFallback: false,
      blocked: {},
      secure: false,
    );

    await CaptureAndroid().setInjectionEnabled(const {});
    await pumpEventQueue();
    expect(payloadOf(configureCalls.last)['injectionEnabled'], <String, bool>{});

    await CaptureAndroid()
        .setInjectionEnabled({'org.telegram.messenger': false});
    await pumpEventQueue();
    expect(payloadOf(configureCalls.last)['injectionEnabled'],
        {'org.telegram.messenger': false});
  });

  test('通道不可用：MissingPluginException 原样抛给调用方（canRequestNotifications 同款兜底契约）',
      () async {
    // 底稿先行（通道还在时推一次完整载荷），再摘掉 control 通道的 mock：
    // Windows 调试 / 引擎未挂时就是这条路径——有底稿的 setInjectionEnabled
    // 会真的走通道并把异常上抛，无底稿时只记录镜像、不碰通道（上一用例的
    // 契约），兜不到这条。
    await CaptureAndroid().configure(
      packages: {'org.telegram.messenger'},
      ocrFallback: false,
      blocked: {},
      secure: false,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, null);

    await expectLater(
      CaptureAndroid().setInjectionEnabled({'org.telegram.messenger': true}),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
