import 'package:chartools_app/application/capture_session.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 场景接线的入口钉子（fix(#11 P0-N)）：[CaptureSession.resolveScenario] 是
/// 采集流与桌面流共用的「scenarioId notifier → ScenarioTemplate」唯一解析点，
/// 这里钳住它的回退口径——**任何「没选/选不出」的输入都落到 null**，而 null
/// 场景在 core 侧（ReplyPrompt 的兼容锁，reply_prompt_test 钉住）提示词与
/// 没有场景功能时逐字节一致。因此：
///
///  - CaptureSession 不注入 scenarioId notifier（旧构造方/工具页）→ 每轮
///    resolveScenario 返回 null → 请求与缓存键和接入前同构，行为不变；
///  - 注入了但存档是空串（未引导）或已下线的 id → 同样 null → 行为不变；
///  - 显式选了 chat_copilot → 返回默认场景模板，其附加段是空串，提示词仍然
///    逐字节一致（scenario.dart 的「默认场景零侵入」承诺）。
///
/// 每轮现读（不是构造时快照）：notifier 值变了，解析结果跟着变——场景切换
/// 下一轮起草立即生效的契约由最后一条测试钉住。
void main() {
  // CaptureSession 的字段初始化器会构造 CaptureAndroid()（构造里给 control
  // 通道 setMethodCallHandler）：通道注册要先有初始化好的 binding，与
  // settings_store_test 等既有 app 测试同一节奏。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CaptureSession.resolveScenario（scenarioId → ScenarioTemplate）', () {
    test('未注入 notifier（null）→ 无场景：不传 scenario 时行为不变', () {
      expect(CaptureSession.resolveScenario(null), isNull);
    });

    test('空串（未引导/未选）→ 无场景', () {
      expect(CaptureSession.resolveScenario(ValueNotifier<String>('')), isNull);
    });

    test('未知 id（已下线场景）→ 无场景，不猜测', () {
      expect(
        CaptureSession.resolveScenario(ValueNotifier<String>('nope')),
        isNull,
      );
    });

    test('chat_copilot → 默认场景模板（附加段空串，提示词不变）', () {
      final scenario =
          CaptureSession.resolveScenario(ValueNotifier<String>('chat_copilot'));
      expect(scenario, isNotNull);
      expect(scenario!.id, 'chat_copilot');
      expect(scenario.systemAddendum, '');
      expect(scenario.userAddendum, '');
    });

    test('内置场景逐个解析到位（蛇形 id）', () {
      for (final expected in Scenarios.builtIns) {
        final scenario =
            CaptureSession.resolveScenario(ValueNotifier<String>(expected.id));
        expect(scenario, isNotNull, reason: '场景 [${expected.id}] 解析失败');
        expect(scenario!.id, expected.id);
      }
    });

    test('每轮现读：notifier 值变了，下一轮解析结果跟着变', () {
      final notifier = ValueNotifier<String>('');
      expect(CaptureSession.resolveScenario(notifier), isNull);

      notifier.value = 'support_agent';
      expect(
        CaptureSession.resolveScenario(notifier)!.id,
        'support_agent',
      );

      notifier.value = 'chat_copilot';
      expect(CaptureSession.resolveScenario(notifier)!.id, 'chat_copilot');

      notifier.value = '';
      expect(CaptureSession.resolveScenario(notifier), isNull);
    });
  });

  group('CaptureSession 构造（scenarioId 可选注入）', () {
    test('不传 scenarioId：字段为 null，轮次解析落到无场景', () {
      // 与既有构造方（工具页/旧测试）逐参兼容：可选参数缺省即旧形状。
      final session = CaptureSession(
        config: ValueNotifier<JevConfig>(JevConfig()),
        relationship: ValueNotifier<String>('朋友'),
        overlayEnabled: ValueNotifier<bool>(true),
      );
      expect(session.scenarioId, isNull);
      expect(CaptureSession.resolveScenario(session.scenarioId), isNull);
      session.dispose();
    });

    test('传入 scenarioId notifier：同一份引用被会话只读持有', () {
      final notifier = ValueNotifier<String>('support_agent');
      final session = CaptureSession(
        config: ValueNotifier<JevConfig>(JevConfig()),
        relationship: ValueNotifier<String>('朋友'),
        overlayEnabled: ValueNotifier<bool>(true),
        scenarioId: notifier,
      );
      expect(session.scenarioId, same(notifier));
      expect(
        CaptureSession.resolveScenario(session.scenarioId)!.id,
        'support_agent',
      );
      session.dispose();
    });
  });
}
