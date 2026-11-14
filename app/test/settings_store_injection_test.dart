/// M0 注入开关镜像（root-module-design.md §3.3-3/§4-M0）—— SettingsStore 侧
/// 契约测试，钉住四条：
///
/// 1. 默认空映射 = 全关（fail-closed）：出厂与「存档没有该键」都落到空映射，
///    映射里没有的包一律按关处理。
/// 2. 持久化往返：'injectionEnabled' 键随整包存档写盘、load 原样读回（true/false
///    都保真）；坏形状（非 Map / 非布尔值）整键丢弃回默认空映射，不抛不挡启动。
/// 3. 变更即推送（开关镜像契约「变更时随既有 configure 推送路径下发」）：
///    门面已有完整载荷底稿时，store 变更立即触发一次 configure MethodCall，
///    载荷完整（packages 原样——孤键载荷会清空 Kotlin 白名单）且 injectionEnabled
///    键为最新值。
/// 4. 无底稿时并入下次推送：本会话从未 configure 过，store 变更只记录镜像，
///    随下次 configure 的载荷带出 injectionEnabled 键。
///
/// fake 通道：安全区 mock 与 settings_store_test.dart 同款（save 第一步写
/// secure storage，不 mock 会卡死）；capture_android/control mock 接住 store
/// 监听经 CaptureAndroid.setInjectionEnabled 触发的 configure 调用。
library;

import 'dart:convert';

import 'package:capture_android/capture_android.dart';
import 'package:chartools_app/application/settings_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 通道名与 flutter_secure_storage_platform_interface 的默认通道逐字一致
  // （settings_store_test.dart:20-23 同款）。
  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  // 开关镜像契约的推送落点：capture_android/control 通道（与
  // CaptureAndroid.controlChannelName 同名同值）。
  const controlChannel = MethodChannel('capture_android/control');

  final configureCalls = <MethodCall>[];

  setUp(() {
    // 门面静态态跨用例残留会串味：每个用例从「无底稿 + 空镜像」起步。
    CaptureAndroid.resetInjectionMirrorForTest();
    configureCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, (call) async {
      if (call.method == 'configure') configureCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, null);
  });

  Future<Map<String, dynamic>> readArchive() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('settings');
    return raw == null
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
  }

  test('默认空映射 = 全关：出厂与「存档没有该键」都落空映射', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();
    expect(store.injectionEnabled.value, isEmpty);

    // 存档里没有 injectionEnabled 键（旧版本存档 / 从未开过开关）→ 仍为空。
    SharedPreferences.setMockInitialValues({
      'settings': jsonEncode({'relationship': '朋友'}),
    });
    final store2 = SettingsStore();
    await store2.load();
    expect(store2.injectionEnabled.value, isEmpty);
  });

  test('持久化往返：save 写入 injectionEnabled 键、load 原样读回 true/false', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();
    store.injectionEnabled.value = {'org.telegram.messenger': true};

    await store.save();

    final archive = await readArchive();
    expect(archive['injectionEnabled'], {'org.telegram.messenger': true});

    // 模拟重启：新实例从存档读回同值。
    final store2 = SettingsStore();
    await store2.load();
    expect(store2.injectionEnabled.value, {'org.telegram.messenger': true});

    // 关闭方向同样保真（映射保留显式 false，不靠缺键表达关）。
    store2.injectionEnabled.value = {'org.telegram.messenger': false};
    await store2.save();
    final store3 = SettingsStore();
    await store3.load();
    expect(store3.injectionEnabled.value, {'org.telegram.messenger': false});
  });

  test('坏形状整键丢弃回默认空映射：非 Map 与非布尔值都不抛、不挡启动', () async {
    SharedPreferences.setMockInitialValues({
      'settings': jsonEncode({
        'injectionEnabled': 'garbage',
      }),
    });
    final store = SettingsStore();
    await store.load();
    expect(store.injectionEnabled.value, isEmpty);

    // 逐项过滤：值不是 bool 的条目被丢弃，合法条目保留。
    SharedPreferences.setMockInitialValues({
      'settings': jsonEncode({
        'injectionEnabled': {'org.telegram.messenger': 'yes'},
      }),
    });
    final store2 = SettingsStore();
    await store2.load();
    expect(store2.injectionEnabled.value, isEmpty);
  });

  test('变更即推送（有底稿）：立即重推完整 configure，injectionEnabled 键为最新值', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();

    // 先造完整载荷底稿（模拟采集页进页的 _pushConfigure）。
    await CaptureAndroid().configure(
      packages: {'com.tencent.mobileqq', 'org.telegram.messenger'},
      ocrFallback: true,
      blocked: {'com.unionpay'},
      secure: true,
    );
    expect(configureCalls, hasLength(1));

    // store 变更 → 监听触发 setInjectionEnabled → 立即重推。
    store.injectionEnabled.value = {'org.telegram.messenger': true};
    await pumpEventQueue();

    expect(configureCalls, hasLength(2));
    final args = configureCalls.last.arguments as Map<Object?, Object?>;
    // 契约键名逐字：injectionEnabled。
    expect(args['injectionEnabled'], {'org.telegram.messenger': true});
    // 载荷完整：孤键载荷会清空 Kotlin 白名单（packages 键缺省 = 恒替换为
    // 空集），重推必须原样带上 packages/blocked/ocrFallback/secure。
    expect(args['packages'],
        ['com.tencent.mobileqq', 'org.telegram.messenger']);
    expect(args['blocked'], ['com.unionpay']);
    expect(args['ocrFallback'], true);
    expect(args['secure'], true);
  });

  test('变更即推送（无底稿）：只记录镜像，随下次 configure 的载荷带出', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();

    store.injectionEnabled.value = {'org.telegram.messenger': true};
    await pumpEventQueue();

    // 本会话从未完整下发过：不发孤键载荷，一次 configure 都没有。
    expect(configureCalls, isEmpty);

    // 下次 configure（采集页进页）原样带出门面镜像。
    await CaptureAndroid().configure(
      packages: {'org.telegram.messenger'},
      ocrFallback: false,
      blocked: {},
      secure: false,
    );
    expect(configureCalls, hasLength(1));
    final args = configureCalls.last.arguments as Map<Object?, Object?>;
    expect(args['injectionEnabled'], {'org.telegram.messenger': true});
  });

  test('开关镜像的清单钳制：injectionScopedPackages 与 Kotlin HookTargets.SCOPED 同值', () {
    // 与 packages/capture_android/android/src/main/kotlin/dev/chartools/capture/
    // bridge/HookTargets.kt:23 的 SCOPED 互钳（legacy
    // com/jev/probe/bridge/HookTargets.kt:20 对位移植）。谁单侧改清单，两边
    // 测试各红一个。
    expect(SettingsStore.injectionScopedPackages, ['org.telegram.messenger']);
  });
}
