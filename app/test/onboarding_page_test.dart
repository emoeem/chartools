// 引导页「完成」的写盘失败路径（kimi-review 第 3 轮 #9，fix(#9 K-6)）：
// save() 抛异常时，SnackBar 文案要明说「下次启动会再看到本页」——内存态
// 已生效、onboarded 标记没落盘，用户不该误以为引导已经存进盘里。
//
// fake 注入：save() 的失败经 flutter_secure_storage 的 MethodChannel 注入
// （secure 写失败上抛、prefs 照常落盘、异常最终上抛——两步隔离见
// settings_store.dart save 的注释），通道名与 mock 方式和
// settings_store_test.dart 完全一致。引导页自身的 Android 权限查询走的
// 是采集通道，测试里没有 mock——页内 catch 把它落成「未知」，不影响本测。
import 'package:chartools_app/application/settings_store.dart';
import 'package:chartools_app/ui/onboarding_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 通道名与 flutter_secure_storage_platform_interface 的
  // MethodChannelFlutterSecureStorage 默认通道逐字一致。
  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  /// 挂上 [failWrites] 指定的 secure 写行为，把引导页泵起来并返回 store。
  Future<SettingsStore> pumpOnboarding(WidgetTester tester,
      {required bool failWrites}) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
      if (failWrites &&
          (call.method == 'write' || call.method == 'delete')) {
        throw PlatformException(code: 'secure_write_failed');
      }
      return null;
    });
    final store = SettingsStore();
    // key 非空才走 secure write 路径（空值是 delete，注入面不一样——见
    // settings_store_test.dart 的同款前置）。
    store.config.value.replyKey = 'sk-onboarding-test';
    store.config.value.judgeKey = 'sk-judge-onboarding-test';
    await tester.pumpWidget(MaterialApp(
      home: OnboardingPage(
        store: store,
        homeBuilder: (_) =>
            const Scaffold(body: Center(child: Text('场景首页'))),
      ),
    ));
    await tester.pump(); // initState 的权限查询（通道失败落「未知」）。
    return store;
  }

  /// 从第一步连点「下一步」到第三步，「完成」按钮才出现。
  Future<void> goToLastPage(WidgetTester tester) async {
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
  }

  testWidgets('fix(#9 K-6) 写盘失败：SnackBar 明说下次启动会再看到本页，本轮照常进首页',
      (tester) async {
    final store = await pumpOnboarding(tester, failWrites: true);
    await goToLastPage(tester);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    // 失败提示保留原有前缀，并补上「下次启动会再看到本页」一句。
    expect(find.textContaining('已生效但写盘失败'), findsOneWidget);
    expect(find.textContaining('下次启动会再看到本页'), findsOneWidget);
    // 写盘失败不拦进首页：homeBuilder 的页面已替换上来（既有降级行为）。
    expect(find.text('场景首页'), findsOneWidget);
    // 内存态照旧生效：onboarded 标记本轮已置 true——文案说的是「下次启动」
    // 才会再看到本页，本轮行为不变。
    expect(store.onboarded.value, isTrue);
  });

  testWidgets('写盘成功路径不出现这句提示（防文案顺手加到两个分支）', (tester) async {
    final store = await pumpOnboarding(tester, failWrites: false);
    await goToLastPage(tester);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.textContaining('下次启动会再看到本页'), findsNothing);
    expect(find.text('场景首页'), findsOneWidget);
    expect(store.onboarded.value, isTrue);
  });
}
