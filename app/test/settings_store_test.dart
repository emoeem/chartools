// F2 迁移测试（p0-plan 问题修复包）：旧版把 replyKey/judgeKey 明文整包存进
// shared_preferences，load 读到即搬入 secure storage 并从存档删除原值，迁移
// 幂等。SettingsStore 是 app 层私有类，core 测不了它——core 侧配套钉的是
// JevConfig.toJson/fromJson 往返无损（packages/core/test/jev_config_test.dart）。
//
// fake 注入门面：单测里没有平台实现，SettingsStore 持有的 FlutterSecureStorage
// 门面走默认 MethodChannelFlutterSecureStorage（见 flutter_secure_storage
// platform interface 的 instance 默认值），所以直接 mock 它的 method channel
// ——不 import 平台接口包（app 没直接依赖它），也不改 SettingsStore 的构造。
import 'dart:convert';

import 'package:chartools_app/application/settings_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 通道名与 flutter_secure_storage_platform_interface 的
  // MethodChannelFlutterSecureStorage 默认通道逐字一致（it_nomads 带下划线）。
  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  // 安全区 fake 的内存态与写计数。写计数是幂等断言的抓手：第二次 load
  // 不该再写一次安全区。
  final secureStore = <String, String>{};
  var secureWrites = 0;
  var failWrites = false;

  setUp(() {
    secureStore.clear();
    secureWrites = 0;
    failWrites = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
      final args = (call.arguments ?? <Object?, Object?>{}) as Map;
      switch (call.method) {
        case 'write':
          if (failWrites) {
            throw PlatformException(code: 'secure_write_failed');
          }
          secureStore[args['key'] as String] = args['value'] as String;
          secureWrites++;
          return null;
        case 'read':
          return secureStore[args['key'] as String];
        case 'delete':
          secureStore.remove(args['key'] as String);
          return null;
        case 'containsKey':
          return secureStore.containsKey(args['key'] as String);
        case 'readAll':
          return Map<String, String>.of(secureStore);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  // 旧版（F2 之前）的存档形状：config 里带明文 key。
  Future<void> seedArchive(Map<String, Object?> archive) async {
    SharedPreferences.setMockInitialValues({'settings': jsonEncode(archive)});
  }

  Future<Map<String, dynamic>> readArchive() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('settings');
    return raw == null
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
  }

  test('明文 key 迁入安全区：load 后安全区有值、存档不再有明文、config 读回', () async {
    await seedArchive({
      'config': {
        'replyKey': 'sk-reply-plain',
        'judgeKey': 'sk-judge-plain',
        'replyBaseUrl': 'https://api.example.com/v1',
        'replyModel': 'test-model',
      },
      'relationship': '同事',
    });

    final store = SettingsStore();
    await store.load();

    // 明文搬入安全区（键名与 SettingsStore._secureReplyKey/_secureJudgeKey 一致）。
    expect(secureStore['config.replyKey'], 'sk-reply-plain');
    expect(secureStore['config.judgeKey'], 'sk-judge-plain');
    // config 的内存态从安全区读回同值。
    expect(store.config.value.replyKey, 'sk-reply-plain');
    expect(store.config.value.judgeKey, 'sk-judge-plain');
    // 其余字段不丢。
    expect(store.config.value.replyBaseUrl, 'https://api.example.com/v1');
    expect(store.config.value.replyModel, 'test-model');
    expect(store.relationship.value, '同事');
    // 存档已重写：config 里不再有 key 字段，整包 JSON 也搜不到明文。
    final after = (await readArchive())['config'] as Map<String, dynamic>;
    expect(after.containsKey('replyKey'), isFalse);
    expect(after.containsKey('judgeKey'), isFalse);
    final rawAfter = jsonEncode(await readArchive());
    expect(rawAfter, isNot(contains('sk-reply-plain')));
    expect(rawAfter, isNot(contains('sk-judge-plain')));
  });

  test('迁移幂等：第二次 load 不重复写安全区，明文不复活', () async {
    await seedArchive({
      'config': {
        'replyKey': 'sk-reply-plain',
        'judgeKey': 'sk-judge-plain',
      },
    });

    final first = SettingsStore();
    await first.load();
    final writesAfterFirst = secureWrites;
    final archiveAfterFirst = await readArchive();

    // 模拟重启：同一份 mock 存档与安全区，再 load 一次。
    final second = SettingsStore();
    await second.load();

    // 幂等的核心：迁移过的存档没有明文键，安全区不再被写。
    expect(secureWrites, writesAfterFirst);
    // 值仍读得到（这次走的是安全区合入路径），存档保持干净。
    expect(second.config.value.replyKey, 'sk-reply-plain');
    expect(second.config.value.judgeKey, 'sk-judge-plain');
    expect(await readArchive(), archiveAfterFirst);
  });

  test('安全区写失败：明文保留在存档（宁可维持明文也不丢 key），config 照常读到', () async {
    await seedArchive({
      'config': {'replyKey': 'sk-keep'},
    });
    failWrites = true;

    final store = SettingsStore();
    await store.load();

    expect(secureStore.containsKey('config.replyKey'), isFalse);
    // 存档里的明文没删——下次启动（写成功时）再迁。
    final after = (await readArchive())['config'] as Map<String, dynamic>;
    expect(after['replyKey'], 'sk-keep');
    // 这一轮 config 仍从存档里的明文读到 key，不因迁移失败而丢配置。
    expect(store.config.value.replyKey, 'sk-keep');
  });

  test('已迁移的存档：安全区已有值直接合入，不触发任何迁移写', () async {
    secureStore['config.replyKey'] = 'sk-secure';
    await seedArchive({
      'config': {'replyModel': 'm1'},
      'overlayEnabled': false,
    });

    final store = SettingsStore();
    await store.load();

    expect(secureWrites, 0);
    expect(store.config.value.replyKey, 'sk-secure');
    expect(store.config.value.replyModel, 'm1');
    expect(store.overlayEnabled.value, isFalse);
  });
}
