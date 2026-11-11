import 'package:chartools_core/src/pipeline/usage_stats.dart';
import 'package:test/test.dart';

/// C9 使用统计的回归防护（独立复核发现的覆盖缺口：此前 core 全部测试无一
/// 引用 UsageStats）。钉四块行为：双口径计数与打点语义（失败不加调用数、
/// 缓存命中不进调用数）、reset 清两个口径、toJson/fromJson 往返（会话口径
/// 不进存档、restore 就地恢复保持实例身份）、坏档容错与「失败 ⊆ 调用」
/// 夹取（usage_stats.dart loadJson 的不变量——手改编档不该画出比调用还多
/// 的失败）。
void main() {
  group('打点：双口径计数', () {
    test('recordCall 同时累加累计与会话两个口径', () {
      final stats = UsageStats();
      stats.recordCall(UsageRoute.judge);
      stats.recordCall(UsageRoute.judge);
      stats.recordCall(UsageRoute.reply);

      expect(stats.calls(UsageRoute.judge), 2);
      expect(stats.calls(UsageRoute.judge, session: true), 2);
      expect(stats.calls(UsageRoute.reply), 1);
      expect(stats.calls(UsageRoute.reply, session: true), 1);
      expect(stats.calls(UsageRoute.review), 0);
      expect(stats.calls(UsageRoute.polish), 0);
    });

    test('recordFailure 只补失败那一笔，不加调用数', () {
      final stats = UsageStats()..recordCall(UsageRoute.judge);
      stats.recordFailure(UsageRoute.judge);
      stats.recordFailure(UsageRoute.judge);

      expect(stats.failures(UsageRoute.judge), 2);
      expect(stats.failures(UsageRoute.judge, session: true), 2);
      // 失败 ⊆ 调用：失败那一笔不复记调用。
      expect(stats.calls(UsageRoute.judge), 1);
    });

    test('缓存命中不进调用数（judge/draft 缓存语义的不变量）', () {
      final stats = UsageStats()
        ..recordCacheHit(UsageRoute.reply)
        ..recordCacheHit(UsageRoute.judge);

      expect(stats.cacheHits(UsageRoute.reply), 1);
      expect(stats.cacheHits(UsageRoute.judge, session: true), 1);
      expect(stats.calls(UsageRoute.reply), 0);
      expect(stats.calls(UsageRoute.judge), 0);
    });
  });

  group('reset / 双口径独立', () {
    test('reset 清零两个口径（设置页重置按钮的语义）', () {
      final stats = UsageStats()
        ..recordCall(UsageRoute.judge)
        ..recordFailure(UsageRoute.judge)
        ..recordCacheHit(UsageRoute.reply);

      stats.reset();

      for (final route in UsageRoute.values) {
        expect(stats.calls(route), 0, reason: route.name);
        expect(stats.failures(route), 0, reason: route.name);
        expect(stats.cacheHits(route), 0, reason: route.name);
        expect(stats.calls(route, session: true), 0, reason: route.name);
        expect(stats.failures(route, session: true), 0, reason: route.name);
        expect(stats.cacheHits(route, session: true), 0, reason: route.name);
      }
    });
  });

  group('toJson / restore 往返', () {
    test('形状：键为路由名，每路由三计数', () {
      final stats = UsageStats()
        ..recordCall(UsageRoute.judge)
        ..recordCall(UsageRoute.judge)
        ..recordFailure(UsageRoute.judge)
        ..recordCacheHit(UsageRoute.judge)
        ..recordCall(UsageRoute.reply);

      expect(stats.toJson(), {
        'judge': {'calls': 2, 'failures': 1, 'cacheHits': 1},
        'reply': {'calls': 1, 'failures': 0, 'cacheHits': 0},
        'review': {'calls': 0, 'failures': 0, 'cacheHits': 0},
        'polish': {'calls': 0, 'failures': 0, 'cacheHits': 0},
      });
    });

    test('fromJson 往返：累计口径恢复、会话口径从零（会话不进存档）', () {
      final stats = UsageStats()
        ..recordCall(UsageRoute.judge)
        ..recordFailure(UsageRoute.judge)
        ..recordCall(UsageRoute.polish);
      final restored = UsageStats.fromJson(stats.toJson());

      expect(restored.calls(UsageRoute.judge), 1);
      expect(restored.failures(UsageRoute.judge), 1);
      expect(restored.calls(UsageRoute.polish), 1);
      // 会话口径的定义就是启动清零，不随存档恢复。
      expect(restored.calls(UsageRoute.judge, session: true), 0);
      expect(restored.failures(UsageRoute.judge, session: true), 0);
    });

    test('restore 就地恢复：实例身份不变（store.usage 的引用始终有效）', () {
      final stats = UsageStats()..recordCall(UsageRoute.reply);
      final fresh = UsageStats();
      final same = fresh;
      fresh.restore(stats.toJson());

      expect(identical(fresh, same), isTrue);
      expect(fresh.calls(UsageRoute.reply), 1);
    });

    test('restore(null)：不改任何计数，不抛', () {
      final stats = UsageStats()..recordCall(UsageRoute.judge);
      stats.restore(null);
      expect(stats.calls(UsageRoute.judge), 1);
    });
  });

  group('坏档容错与夹取', () {
    test('坏形状逐项落 0：非 map / 非正数 / 负数 / 非 int 类型', () {
      final restored = UsageStats.fromJson({
        'judge': '不是 map',
        'reply': {'calls': '不是数字', 'failures': -3, 'cacheHits': 1.5},
        'review': {'calls': 0},
      });

      expect(restored.calls(UsageRoute.judge), 0);
      expect(restored.calls(UsageRoute.reply), 0);
      expect(restored.failures(UsageRoute.reply), 0);
      expect(restored.cacheHits(UsageRoute.reply), 0);
      expect(restored.calls(UsageRoute.review), 0);
    });

    test('failures > calls 夹回 calls：手改编档不画出比调用还多的失败', () {
      final restored = UsageStats.fromJson({
        'judge': {'calls': 3, 'failures': 9, 'cacheHits': 0},
        'reply': {'calls': 0, 'failures': 2, 'cacheHits': 0},
        'polish': {'calls': 5, 'failures': 5, 'cacheHits': 0},
      });

      expect(restored.failures(UsageRoute.judge), 3);
      expect(restored.failures(UsageRoute.reply), 0);
      // 恰好相等不夹：失败数可以等于调用数。
      expect(restored.failures(UsageRoute.polish), 5);
    });

    test('多余键忽略、缺键落 0（fromJson 全新实例的容错口径）', () {
      final restored = UsageStats.fromJson({
        'no_such_route': {'calls': 42, 'failures': 42, 'cacheHits': 42},
        'judge': {'calls': 7},
      });

      expect(restored.calls(UsageRoute.judge), 7);
      expect(restored.failures(UsageRoute.judge), 0);
      expect(restored.cacheHits(UsageRoute.judge), 0);
      expect(restored.calls(UsageRoute.reply), 0);
      expect(restored.calls(UsageRoute.polish), 0);
    });
  });
}
