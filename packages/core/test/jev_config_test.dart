import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// JevConfig 的 JSON 往返与路由推导单测 —— p0-plan F2 的 core 侧配套：
/// SettingsStore 的密钥迁移无法在 core 测（它住在 app 层），这里钉住的是
/// 迁移赖以成立的数据契约：toJson/fromJson 全字段无损，含 A4 新增的润色
/// 路由三字段（polishBaseUrl/polishKey/polishModel）。
void main() {
  // 全字段非默认值的一份配置：往返测试的输入。每个字段都与类内默认值不同，
  // 「写进去的都读得回来」才不是碰巧（默认值字段往返时丢键测不出来）。
  JevConfig fullConfig() => JevConfig()
    ..judgeProvider = 'bocha'
    ..judgeBaseUrl = 'https://judge.example.com'
    ..judgeKey = 'judge-key'
    ..judgeModel = 'judge-model'
    ..judgeProtocol = 'chat'
    ..replyBaseUrl = 'https://reply.example.com/v1'
    ..replyKey = 'reply-key'
    ..replyModel = 'reply-model'
    ..reviewEnabled = true
    ..reviewBaseUrl = 'https://review.example.com/v1'
    ..reviewKey = 'review-key'
    ..reviewModel = 'review-model'
    ..polishBaseUrl = 'https://polish.example.com/v1'
    ..polishKey = 'polish-key'
    ..polishModel = 'polish-model'
    ..style = '克制，短句'
    ..replyLanguage = 'zh'
    ..replyLength = 'short'
    ..replyTemperature = 0.6
    ..replyFrequencyPenalty = 0.5
    ..replyPresencePenalty = 0.4
    ..contextHistoryCount = 10
    ..usePositiveExamples = true;

  group('JSON 往返', () {
    test('全字段往返无损，含 A4 新增的润色路由三字段', () {
      final c = fullConfig();

      final restored = JevConfig.fromJson(c.toJson());

      // 整表相等：toJson 的键一个不少——toJson 侧加了字段忘了 fromJson 读，
      // 或反过来，都会在这里对不上。
      expect(restored.toJson(), c.toJson());
      // 逐字段点名，失败时能直接看到是哪一个丢了。
      expect(restored.judgeProvider, 'bocha');
      expect(restored.judgeBaseUrl, 'https://judge.example.com');
      expect(restored.judgeKey, 'judge-key');
      expect(restored.judgeModel, 'judge-model');
      expect(restored.judgeProtocol, 'chat');
      expect(restored.replyBaseUrl, 'https://reply.example.com/v1');
      expect(restored.replyKey, 'reply-key');
      expect(restored.replyModel, 'reply-model');
      expect(restored.reviewEnabled, isTrue);
      expect(restored.reviewBaseUrl, 'https://review.example.com/v1');
      expect(restored.reviewKey, 'review-key');
      expect(restored.reviewModel, 'review-model');
      expect(restored.polishBaseUrl, 'https://polish.example.com/v1');
      expect(restored.polishKey, 'polish-key');
      expect(restored.polishModel, 'polish-model');
      expect(restored.style, '克制，短句');
      expect(restored.replyLanguage, 'zh');
      expect(restored.replyLength, 'short');
      expect(restored.replyTemperature, closeTo(0.6, 1e-9));
      expect(restored.replyFrequencyPenalty, closeTo(0.5, 1e-9));
      expect(restored.replyPresencePenalty, closeTo(0.4, 1e-9));
      expect(restored.contextHistoryCount, 10);
      expect(restored.usePositiveExamples, isTrue);
    });

    test('缺键一律落回默认值：旧存档读不炸，润色字段默认空（回退回复路由）', () {
      final c = JevConfig.fromJson(const {});

      expect(c.polishBaseUrl, '');
      expect(c.polishKey, '');
      expect(c.polishModel, '');
      expect(c.replyBaseUrl, 'https://openrouter.ai/api/v1');
      expect(c.reviewEnabled, isFalse);
      expect(c.replyTemperature, closeTo(0.8, 1e-9));
      expect(c.contextHistoryCount, 30);
    });

    test('空串与缺键语义有别：填过又清空的字段往返后仍是空串', () {
      // toJson 的注释契约：空串 ≠ 缺键（「用户填过又清空」vs「从没填过」）。
      final c = JevConfig()
        ..polishBaseUrl = ''
        ..polishKey = '   '
        ..reviewBaseUrl = '';

      final restored = JevConfig.fromJson(c.toJson());
      expect(restored.toJson(), c.toJson());
      expect(restored.polishKey, '   '); // 原样带回，不代 trim
    });

    test('copyWith 覆盖润色字段，null 保持原值', () {
      final c = fullConfig();

      final changed = c.copyWith(polishModel: 'another-model');
      expect(changed.polishModel, 'another-model');
      expect(changed.polishBaseUrl, 'https://polish.example.com/v1');
      expect(changed.polishKey, 'polish-key');

      final untouched = c.copyWith();
      expect(untouched.toJson(), c.toJson());
    });
  });

  group('润色路由推导（A4，回退规则与复查路由同模式）', () {
    test('三字段留空：端点、密钥、模型全部沿用回复路由', () {
      final c = JevConfig()
        ..replyBaseUrl = 'https://reply.example.com/v1/'
        ..replyKey = 'reply-key'
        ..judgeKey = 'judge-key'
        ..replyModel = 'reply-model';

      // base 留空回退 replyBaseUrl，尾部斜杠同样剥掉。
      expect(c.polishEndpoint(), 'https://reply.example.com/v1/chat/completions');
      // 密钥链：polishKey 空 → 回复路由的实际生效密钥（replyKey → judgeKey）。
      expect(c.effectivePolishKey(), 'reply-key');
      // 模型链：polishModel 空 → replyModel。
      expect(c.effectivePolishModel(), 'reply-model');
    });

    test('回复密钥也空时润色密钥落到判断密钥', () {
      final c = JevConfig()
        ..replyKey = ''
        ..judgeKey = 'judge-key';

      expect(c.effectivePolishKey(), 'judge-key');
    });

    test('润色三字段非空：各自生效，互不接复查路由的力', () {
      final c = JevConfig()
        ..replyBaseUrl = 'https://reply.example.com/v1'
        ..replyKey = 'reply-key'
        ..replyModel = 'reply-model'
        ..reviewBaseUrl = 'https://review.example.com/v1'
        ..reviewKey = 'review-key'
        ..reviewModel = 'review-model'
        ..polishBaseUrl = 'https://polish.example.com/v1///'
        ..polishKey = 'polish-key'
        ..polishModel = 'polish-model';

      // 端点独立拼自己的 base（多个尾部斜杠一次剥净）。
      expect(c.polishEndpoint(), 'https://polish.example.com/v1/chat/completions');
      // 润色密钥不经过复查密钥：reviewKey 非空也轮不到它。
      expect(c.effectivePolishKey(), 'polish-key');
      expect(c.effectivePolishModel(), 'polish-model');
    });

    test('润色密钥为空白字符按留空处理（ifBlank 语义）', () {
      final c = JevConfig()
        ..replyKey = 'reply-key'
        ..polishKey = '   ';

      expect(c.effectivePolishKey(), 'reply-key');
    });
  });

  group('既有路由推导回归', () {
    test('复查路由行为不被润色路由改动', () {
      // 润色字段进来时，复查端点/密钥/模型的推导必须原样。
      final c = fullConfig();
      expect(c.reviewEndpoint(), 'https://review.example.com/v1/chat/completions');
      expect(c.effectiveReviewKey(), 'review-key');
      expect(c.effectiveReviewModel(), 'review-model');
    });
  });
}
